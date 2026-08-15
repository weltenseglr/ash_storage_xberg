defmodule AshStorageXberg.AnalyzersTest do
  use ExUnit.Case, async: false

  alias AshStorageXberg.Analyzers.Audio
  alias AshStorageXberg.Analyzers.ContentType
  alias AshStorageXberg.Analyzers.Document
  alias AshStorageXberg.Analyzers.Image
  alias AshStorageXberg.Analyzers.Text
  alias AshStorageXberg.Formats

  @pdf Path.expand("../support/fixtures/CELEX_12016P_TXT_DE_TXT.pdf", __DIR__)
  @png Path.expand("../support/fixtures/good-scan-example-d-619x1024.png", __DIR__)
  @docx Path.expand("../support/fixtures/fixture.docx", __DIR__)
  @wav Path.expand("../support/fixtures/testaudio_44100_test01_20s.wav", __DIR__)

  @formats [
    %{"extension" => "pdf", "mime_type" => "application/pdf"},
    %{
      "extension" => "docx",
      "mime_type" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    },
    %{"extension" => "epub", "mime_type" => "application/epub+zip"},
    %{"extension" => "png", "mime_type" => "image/png"},
    %{"extension" => "txt", "mime_type" => "text/plain"},
    %{"extension" => "wav", "mime_type" => "audio/wav"}
  ]

  setup do
    Application.put_env(:ash_storage_xberg, :req_options,
      plug: {Req.Test, AshStorageXberg.XbergApi},
      retry: false
    )

    # Warm the format cache from a controlled list so `accept?/1` never reaches
    # for the network mid-test (and never leaks into other test files).
    Req.Test.stub(AshStorageXberg.XbergApi, &Req.Test.json(&1, @formats))
    Formats.reset()
    _ = Formats.mime_types()

    on_exit(fn ->
      Application.delete_env(:ash_storage_xberg, :req_options)
      Formats.reset()
    end)

    :ok
  end

  defp stub_extract(envelope, assert_params \\ fn _params -> :ok end) do
    Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
      assert conn.request_path == "/extract"

      opts = Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: 50_000_000)
      conn = Plug.Parsers.call(conn, opts)

      assert_params.(conn.params)
      Req.Test.json(conn, envelope)
    end)
  end

  defp envelope(result), do: %{"results" => [result], "summary" => %{"errors" => 0}}

  defp config(params), do: Jason.decode!(params["config"])

  describe "ContentType" do
    test "accepts every content type" do
      assert ContentType.accept?("application/pdf")
      assert ContentType.accept?("application/octet-stream")
    end

    test "detects the MIME type via /detect" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        assert conn.request_path == "/detect"

        Req.Test.json(conn, %{
          "mime_type" => "application/pdf",
          "filename" => "CELEX_12016P_TXT_DE_TXT.pdf"
        })
      end)

      assert {:ok, result} = ContentType.analyze(@pdf, [])
      assert result == %{"detected_content_type" => "application/pdf"}
    end

    test "verifies the detected type against the claimed one" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, %{"mime_type" => "application/pdf"})
      end)

      assert {:ok, %{"content_type_verified" => true}} =
               ContentType.analyze(@pdf, content_type: "Application/PDF; charset=binary")

      assert {:ok, %{"content_type_verified" => false}} =
               ContentType.analyze(@pdf, content_type: "image/png")
    end

    test "passes sidecar errors through" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error_type" => "ValidationError", "message" => "bad request"})
      end)

      assert {:error, {:validation_error, "bad request"}} = ContentType.analyze(@pdf, [])
    end

    # The backend choice is exclusive: a NIF-only deployment has no sidecar to
    # reach. This analyzer used to call `XbergApi.detect/1` directly, so it was
    # the one analyzer that could not work there.
    test "works on a backend with no detect/1, via a metadata-only extraction" do
      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.DetectlessNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      Req.Test.stub(AshStorageXberg.XbergApi, fn _conn ->
        flunk("ContentType reached the REST sidecar on a NIF-only deployment")
      end)

      assert {:ok, %{"detected_content_type" => "application/pdf"}} =
               ContentType.analyze(@pdf, [])

      assert {:ok, %{"content_type_verified" => true}} =
               ContentType.analyze(@pdf, content_type: "application/pdf")
    end

    test "prefers the backend's own detect/1 when it has one" do
      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.DetectingNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      assert {:ok, %{"detected_content_type" => "image/png"}} = ContentType.analyze(@pdf, [])
    end

    test "surfaces backend errors from the fallback path" do
      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.FailingNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      assert {:error, {:parsing_error, "bad pdf"}} = ContentType.analyze(@pdf, [])
    end
  end

  describe "Image" do
    test "accepts image content types only" do
      assert Image.accept?("image/png")
      assert Image.accept?("image/svg+xml")
      assert Image.accept?("IMAGE/PNG")
      assert Image.accept?("Image/Jpeg; qs=0.9")
      refute Image.accept?("application/pdf")
      refute Image.accept?(nil)
    end

    test "returns dimensions, format, and EXIF without paying for OCR" do
      stub_extract(
        envelope(%{
          "content" => "",
          "mime_type" => "image/png",
          "metadata" => %{
            "ocr_used" => false,
            "format" => %{
              "format_type" => "image",
              "width" => 3,
              "height" => 2,
              "format" => "PNG",
              "exif" => %{"Make" => "ACME"}
            }
          }
        }),
        fn params -> assert config(params)["disable_ocr"] == true end
      )

      assert {:ok, result} = Image.analyze(@png, [])

      assert result == %{
               "width" => 3,
               "height" => 2,
               "format" => "PNG",
               "exif" => %{"Make" => "ACME"}
             }
    end

    test "defaults EXIF to an empty map" do
      stub_extract(envelope(%{"metadata" => %{"format" => %{"width" => 1, "height" => 1}}}))

      assert {:ok, %{"exif" => %{}} = result} = Image.analyze(@png, [])
      refute Map.has_key?(result, "format")
    end
  end

  describe "Audio" do
    test "accepts audio and video content types" do
      assert Audio.accept?("audio/mpeg")
      assert Audio.accept?("video/mp4")
      assert Audio.accept?("AUDIO/MPEG")
      assert Audio.accept?("Video/MP4; codecs=avc1")
      refute Audio.accept?("image/png")
      refute Audio.accept?(nil)
    end

    test "requests only media metadata and normalizes reported fields" do
      stub_extract(
        envelope(%{
          "content" => "must not become analyzer metadata",
          "metadata" => %{
            "format" => %{
              "format_type" => "audio",
              "duration_seconds" => 1.5,
              "codec" => "pcm_s16le",
              "container" => "wav",
              "sample_rate" => 8000,
              "channels" => 1
            },
            "additional" => %{"bitrate" => 128_000}
          }
        }),
        fn params ->
          assert config(params) == %{"disable_ocr" => true}
        end
      )

      assert {:ok, result} = Audio.analyze(@wav, [])

      assert result == %{
               "duration_ms" => 1500,
               "codec" => "pcm_s16le",
               "container" => "wav",
               "sample_rate_hz" => 8000,
               "channels" => 1,
               "bitrate" => 128_000
             }
    end

    test "maps unknown per-input errors to a finite fallback" do
      stub_extract(%{
        "results" => [],
        "errors" => [%{"error_type" => "AttackerControlledError", "message" => "failed"}]
      })

      assert {:error, {:unknown_error, "failed"}} = Audio.analyze(@wav, [])
    end

    test "surfaces per-input extraction errors from the envelope" do
      stub_extract(%{
        "results" => [],
        "errors" => [
          %{
            "index" => 0,
            "code" => 1003,
            "error_type" => "unsupported_format",
            "source" => "testaudio_44100_test01_20s.wav",
            "message" => "Unsupported format: audio/wav"
          }
        ],
        "summary" => %{"errors" => 1}
      })

      assert {:error, {:unsupported_format, "Unsupported format: audio/wav"}} =
               Audio.analyze(@wav, [])
    end
  end

  describe "Document" do
    test "accepts document content types the sidecar supports" do
      assert Document.accept?("application/pdf")
      assert Document.accept?("Application/PDF; qs=0.9")

      assert Document.accept?(
               "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
             )

      assert Document.accept?("application/epub+zip")
      refute Document.accept?("image/png")
      refute Document.accept?("text/plain")
      refute Document.accept?(nil)
    end

    test "returns bibliographic metadata, omitting what the document lacks" do
      stub_extract(
        envelope(%{
          "content" => "Docx fixture body text",
          "metadata" => %{
            "title" => "Fixture Title",
            "authors" => ["Fixture Author"],
            "created_by" => "Fixture Author",
            "format" => %{"format_type" => "docx"}
          },
          "counts" => %{"pages" => 1, "tables" => 0, "images" => 0}
        }),
        fn params ->
          assert config(params)["disable_ocr"] == true
          assert config(params)["language_detection"] == %{"enabled" => true}
        end
      )

      assert {:ok, result} = Document.analyze(@docx, [])

      assert result == %{
               "title" => "Fixture Title",
               "authors" => ["Fixture Author"],
               "page_count" => 1
             }
    end

    test "prefers the format page count and detected language" do
      stub_extract(
        envelope(%{
          "metadata" => %{
            "created_at" => "2026-08-11T10:00:00Z",
            "format" => %{"format_type" => "pdf", "page_count" => 12}
          },
          "counts" => %{"pages" => 0},
          "detected_languages" => ["eng", "deu"]
        })
      )

      assert {:ok,
              %{
                "page_count" => 12,
                "language" => "eng",
                "created_at" => "2026-08-11T10:00:00Z"
              }} = Document.analyze(@pdf, [])
    end
  end

  describe "Text" do
    test "accepts whatever the sidecar can extract" do
      assert Text.accept?("application/pdf")
      assert Text.accept?("text/plain; charset=utf-8")
      refute Text.accept?("application/x-does-not-exist")
      refute Text.accept?(nil)
    end

    test "returns text, language, word count, and OCR usage" do
      stub_extract(
        envelope(%{
          "content" => "Hello from AshStorage Xberg",
          "metadata" => %{"ocr_used" => false, "format" => %{"format_type" => "pdf"}},
          "detected_languages" => ["eng"]
        }),
        fn params ->
          assert config(params) == %{
                   "output_format" => "plain",
                   "disable_ocr" => true,
                   "language_detection" => %{"enabled" => true}
                 }
        end
      )

      assert {:ok, result} = Text.analyze(@pdf, [])

      assert result == %{
               "text" => "Hello from AshStorage Xberg",
               "language" => "eng",
               "word_count" => 4,
               "ocr_used" => false
             }
    end

    test "returns string keys, as ash_storage's write_attributes lookup expects" do
      stub_extract(envelope(%{"content" => "body", "metadata" => %{}}))

      assert {:ok, result} = Text.analyze(@pdf, [])
      # mirrors AshStorage.Changes.Attach: Map.fetch(result, to_string(result_key))
      assert Map.fetch(result, to_string(:text)) == {:ok, "body"}
    end

    test "translates :output, :ocr, and :timeout into extraction config" do
      stub_extract(
        envelope(%{"content" => "# Title", "metadata" => %{"ocr_used" => true}}),
        fn params ->
          assert config(params) == %{
                   "output_format" => "markdown",
                   "disable_ocr" => false,
                   "language_detection" => %{"enabled" => true},
                   "extraction_timeout_secs" => 30
                 }
        end
      )

      assert {:ok, %{"ocr_used" => true}} =
               Text.analyze(@pdf, output: :markdown, ocr: true, timeout: 30)
    end

    test "truncates on a UTF-8 boundary and flags the truncation" do
      # "ä" is two bytes, so a 2-byte cut lands mid-character.
      stub_extract(envelope(%{"content" => "aäb cd", "metadata" => %{}}))

      assert {:ok, %{"text" => "a", "text_truncated" => true, "word_count" => 2}} =
               Text.analyze(@pdf, max_bytes: 2)
    end

    test "does not flag text that fits" do
      stub_extract(envelope(%{"content" => "short", "metadata" => %{}}))

      assert {:ok, result} = Text.analyze(@pdf, max_bytes: 64)
      refute Map.has_key?(result, "text_truncated")
      assert result["text"] == "short"
    end

    test "passes transport failures through as analyzer errors" do
      Req.Test.stub(AshStorageXberg.XbergApi, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport_error, message}} = Text.analyze(@pdf, [])
      assert is_binary(message)
    end

    test "reports a missing file without touching the network" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        flunk("no request expected, got #{conn.request_path}")
      end)

      assert {:error, {:validation_error, message}} = Text.analyze("/no/such/file.pdf", [])
      assert message =~ "file not found"
    end
  end

  # Stand-ins for the `:xberg` NIF, which implements the required callbacks but
  # not the optional `detect/1`.
  defmodule DetectlessNif do
    @behaviour AshStorageXberg.Xberg

    @impl true
    def extract(_opts),
      do: {:ok, %{results: [%{mime_type: "application/pdf", content: "hello"}]}}

    @impl true
    def extract_batch(_opts), do: {:ok, %{results: []}}

    @impl true
    def list_supported_formats, do: []
  end

  defmodule DetectingNif do
    @behaviour AshStorageXberg.Xberg

    @impl true
    def extract(_opts), do: {:ok, %{results: [%{mime_type: "application/pdf"}]}}

    @impl true
    def extract_batch(_opts), do: {:ok, %{results: []}}

    @impl true
    def list_supported_formats, do: []

    @impl true
    def detect(_input), do: {:ok, %{"mime_type" => "image/png"}}
  end

  defmodule FailingNif do
    @behaviour AshStorageXberg.Xberg

    @impl true
    def extract(_opts), do: {:error, :parsing_error, "bad pdf"}

    @impl true
    def extract_batch(_opts), do: {:error, :parsing_error, "bad pdf"}

    @impl true
    def list_supported_formats, do: []
  end
end
