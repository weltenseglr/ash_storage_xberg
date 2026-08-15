defmodule AshStorageXberg.VariantsTest do
  use ExUnit.Case, async: false

  alias AshStorageXberg.Variants.ExtractedText
  alias AshStorageXberg.Variants.PageThumbnail
  alias AshStorageXberg.Variants.Transcript

  @pdf Path.expand("../support/fixtures/CELEX_12016P_TXT_DE_TXT.pdf", __DIR__)
  @png Path.expand("../support/fixtures/good-scan-example-d-619x1024.png", __DIR__)
  @wav Path.expand("../support/fixtures/testaudio_44100_test01_20s.wav", __DIR__)

  setup do
    Application.put_env(:ash_storage_xberg, :req_options,
      plug: {Req.Test, AshStorageXberg.XbergApi},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:ash_storage_xberg, :req_options) end)
    :ok
  end

  # Warm the format cache from a controlled `GET /formats` list so `accept?/1`
  # never reaches for the network mid-test (and never leaks into other files).
  defp warm_formats(formats) do
    Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
      assert conn.request_path == "/formats"
      Req.Test.json(conn, formats)
    end)

    AshStorageXberg.Formats.reset()
    _ = AshStorageXberg.Formats.mime_types()

    on_exit(&AshStorageXberg.Formats.reset/0)
    :ok
  end

  defp config_from(conn) do
    opts = Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: 50_000_000)
    conn = Plug.Parsers.call(conn, opts)
    {conn, Jason.decode!(conn.params["config"] || "{}")}
  end

  defp envelope(result) do
    %{
      "results" => [result],
      "errors" => [],
      "summary" => %{"inputs" => 1, "results" => 1, "errors" => 0}
    }
  end

  defp error_envelope(error_type, message) do
    %{
      "results" => [],
      "errors" => [
        %{"index" => 0, "code" => 1003, "error_type" => error_type, "message" => message}
      ],
      "summary" => %{"inputs" => 1, "results" => 0, "errors" => 1}
    }
  end

  describe "PageThumbnail.accept?/1" do
    setup do
      # The document half of `accept?/1` is intersected with the sidecar's
      # format list, so warm the cache from a controlled one — xberg 1.0.14
      # reports no ODF Graphics.
      warm_formats([
        %{"extension" => "pdf", "mime_type" => "application/pdf"},
        %{
          "extension" => "docx",
          "mime_type" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        },
        %{"extension" => "odt", "mime_type" => "application/vnd.oasis.opendocument.text"},
        %{"extension" => "ods", "mime_type" => "application/vnd.oasis.opendocument.spreadsheet"},
        %{"extension" => "odp", "mime_type" => "application/vnd.oasis.opendocument.presentation"},
        %{"extension" => "png", "mime_type" => "image/png"}
      ])
    end

    test "accepts rasterizable documents and images" do
      assert PageThumbnail.accept?("application/pdf")
      assert PageThumbnail.accept?("application/pdf; charset=binary")
      assert PageThumbnail.accept?("APPLICATION/PDF")

      assert PageThumbnail.accept?(
               "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
             )

      assert PageThumbnail.accept?("application/vnd.oasis.opendocument.text")
      assert PageThumbnail.accept?("application/vnd.oasis.opendocument.spreadsheet")
      assert PageThumbnail.accept?("application/vnd.oasis.opendocument.presentation")
      assert PageThumbnail.accept?("image/png")
      assert PageThumbnail.accept?("image/jpeg")
    end

    test "accepts image types the sidecar does not list as extractable" do
      # `image/*` is deliberately not intersected: the sidecar returns the
      # embedded image rather than a page raster.
      assert PageThumbnail.accept?("image/jpeg")
      assert PageThumbnail.accept?("image/heif")
    end

    test "rejects document types the sidecar cannot extract" do
      refute PageThumbnail.accept?("application/vnd.oasis.opendocument.graphics")
      refute PageThumbnail.accept?("application/epub+zip")
    end

    test "rejects everything else" do
      refute PageThumbnail.accept?("audio/mpeg")
      refute PageThumbnail.accept?("text/plain")
      refute PageThumbnail.accept?(nil)
    end
  end

  describe "PageThumbnail.accept?/1 on a build with ODF Graphics" do
    setup do
      warm_formats([
        %{"extension" => "odg", "mime_type" => "application/vnd.oasis.opendocument.graphics"}
      ])
    end

    test "accepts whatever the sidecar reports" do
      assert PageThumbnail.accept?("application/vnd.oasis.opendocument.graphics")
      assert PageThumbnail.accept?("APPLICATION/VND.OASIS.OPENDOCUMENT.GRAPHICS")
      refute PageThumbnail.accept?("application/pdf")
    end
  end

  describe "PageThumbnail.transform/3" do
    @describetag :tmp_dir

    defp raster(overrides \\ %{}) do
      Map.merge(
        %{
          "format" => "png",
          "image_index" => 0,
          "page_number" => 1,
          "width" => 1275,
          "height" => 1650,
          "image_kind" => "page_raster",
          "data_base64" => Base.encode64(File.read!(@png))
        },
        overrides
      )
    end

    test "requests page rasters and writes the decoded image", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)

        assert config == %{
                 "force_ocr" => true,
                 "images" => %{
                   "extract_images" => true,
                   "include_page_rasters" => true,
                   "include_data_base64" => true,
                   "target_dpi" => 72,
                   "output_format" => %{"type" => "png"}
                 }
               }

        Req.Test.json(conn, envelope(%{"images" => [raster()]}))
      end)

      dest = Path.join(tmp_dir, "thumb.png")

      assert {:ok, meta} = PageThumbnail.transform(@pdf, dest, [])
      assert meta == %{content_type: "image/png", width: 1275, height: 1650, page: 1}
      assert File.read!(dest) == File.read!(@png)
    end

    test "translates :dpi, :format and :max_dimension options", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)

        assert config["images"]["target_dpi"] == 150
        assert config["images"]["output_format"] == %{"type" => "webp"}
        assert config["images"]["max_image_dimension"] == 512

        Req.Test.json(
          conn,
          envelope(%{
            "images" => [raster(%{"format" => "webp", "width" => 512, "height" => 662})]
          })
        )
      end)

      dest = Path.join(tmp_dir, "thumb.webp")

      assert {:ok, %{content_type: "image/webp", width: 512, height: 662}} =
               PageThumbnail.transform(@pdf, dest, dpi: 150, format: :webp, max_dimension: 512)
    end

    test "picks the requested page", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        page_two = raster(%{"page_number" => 2, "data_base64" => Base.encode64("second-page")})

        Req.Test.json(conn, envelope(%{"images" => [raster(), page_two]}))
      end)

      dest = Path.join(tmp_dir, "page2.png")

      assert {:ok, %{page: 2}} = PageThumbnail.transform(@pdf, dest, page: 2)
      assert File.read!(dest) == "second-page"
    end

    test "falls back to embedded images for image sources", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        embedded =
          raster(%{
            "format" => "PNG",
            "page_number" => nil,
            "image_kind" => "decoration",
            "width" => 3,
            "height" => 2
          })

        Req.Test.json(conn, envelope(%{"images" => [embedded]}))
      end)

      dest = Path.join(tmp_dir, "image.png")

      assert {:ok, %{content_type: "image/png", width: 3, height: 2, page: 1}} =
               PageThumbnail.transform(@png, dest, [])
    end

    test "decodes the raw byte-list form when no base64 is present", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        image = raster() |> Map.delete("data_base64") |> Map.put("data", [1, 2, 3])
        Req.Test.json(conn, envelope(%{"images" => [image]}))
      end)

      dest = Path.join(tmp_dir, "raw.png")

      assert {:ok, _meta} = PageThumbnail.transform(@pdf, dest, [])
      assert File.read!(dest) == <<1, 2, 3>>
    end

    test "errors when the response carries no raster for the page", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, envelope(%{"images" => []}))
      end)

      dest = Path.join(tmp_dir, "missing.png")

      assert {:error, {:no_page_raster, message}} = PageThumbnail.transform(@pdf, dest, page: 3)
      assert message =~ "page 3"
      refute File.exists?(dest)
    end

    test "converts sidecar error tuples", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error_type" => "ValidationError", "message" => "bad config"})
      end)

      assert {:error, {:validation_error, "bad config"}} =
               PageThumbnail.transform(@pdf, Path.join(tmp_dir, "x.png"), [])
    end

    test "converts per-file envelope errors", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, error_envelope("unsupported_format", "Unsupported format: audio/wav"))
      end)

      assert {:error, {:unsupported_format, "Unsupported format: audio/wav"}} =
               PageThumbnail.transform(@pdf, Path.join(tmp_dir, "x.png"), [])
    end

    test "maps unknown per-file errors to a finite fallback", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, error_envelope("AttackerControlledError", "failed"))
      end)

      assert {:error, {:unknown_error, "failed"}} =
               PageThumbnail.transform(@pdf, Path.join(tmp_dir, "x.png"), [])
    end
  end

  describe "ExtractedText.accept?/1" do
    setup do
      AshStorageXberg.Formats.reset()

      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        assert conn.request_path == "/formats"

        Req.Test.json(conn, [
          %{"extension" => "pdf", "mime_type" => "application/pdf"},
          %{"extension" => "docx", "mime_type" => "text/markdown"}
        ])
      end)

      on_exit(&AshStorageXberg.Formats.reset/0)
      :ok
    end

    test "delegates to the cached sidecar format list" do
      assert ExtractedText.accept?("application/pdf")
      assert ExtractedText.accept?("text/markdown; charset=utf-8")
      refute ExtractedText.accept?("application/x-nonsense")
      refute ExtractedText.accept?(nil)
    end
  end

  describe "ExtractedText.transform/3" do
    @describetag :tmp_dir

    defp text_result(overrides \\ %{}) do
      Map.merge(
        %{
          "content" => "# Hello\n\nHello from AshStorage Xberg\n",
          "mime_type" => "application/pdf",
          "metadata" => %{"ocr_used" => false, "language" => "en"},
          "tables" => []
        },
        overrides
      )
    end

    test "writes markdown by default and disables OCR", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)
        assert config == %{"output_format" => "markdown", "disable_ocr" => true}
        Req.Test.json(conn, envelope(text_result()))
      end)

      dest = Path.join(tmp_dir, "text.md")

      assert {:ok, meta} = ExtractedText.transform(@pdf, dest, [])

      assert meta == %{
               content_type: "text/markdown",
               word_count: 6,
               language: "en",
               ocr_used: false
             }

      assert File.read!(dest) == "# Hello\n\nHello from AshStorage Xberg\n"
    end

    # Regression: this counted words with an ASCII-only \s while the Text
    # analyzer used \s with /u, so the same document got two different counts.
    test "counts words across Unicode whitespace", %{tmp_dir: tmp_dir} do
      nbsp_content = "one\u00A0two three"

      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, _config} = config_from(conn)
        Req.Test.json(conn, envelope(text_result(%{"content" => nbsp_content})))
      end)

      assert {:ok, %{word_count: 3}} =
               ExtractedText.transform(@pdf, Path.join(tmp_dir, "nbsp.md"), [])

      assert AshStorageXberg.Result.word_count(nbsp_content) == 3
    end

    test "translates :format, :ocr and :timeout options", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)

        assert config == %{
                 "output_format" => "plain",
                 "disable_ocr" => false,
                 "extraction_timeout_secs" => 45
               }

        Req.Test.json(conn, envelope(text_result(%{"content" => "plain text"})))
      end)

      dest = Path.join(tmp_dir, "text.txt")

      assert {:ok, %{content_type: "text/plain", word_count: 2}} =
               ExtractedText.transform(@pdf, dest, format: :plain, ocr: true, timeout: 45)

      assert File.read!(dest) == "plain text"
    end

    test "writes a JSON document for format: :json", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)
        assert config["output_format"] == "markdown"

        Req.Test.json(
          conn,
          envelope(text_result(%{"tables" => [%{"rows" => [["a", "b"]]}]}))
        )
      end)

      dest = Path.join(tmp_dir, "text.json")

      assert {:ok, %{content_type: "application/json"}} =
               ExtractedText.transform(@pdf, dest, format: :json)

      assert %{"content" => content, "metadata" => metadata, "tables" => [table]} =
               dest |> File.read!() |> Jason.decode!()

      assert content =~ "Hello from AshStorage Xberg"
      assert metadata["language"] == "en"
      assert table == %{"rows" => [["a", "b"]]}
    end

    test "falls back to detected_languages and omits unknown metadata", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(
          conn,
          envelope(%{
            "content" => "bonjour",
            "metadata" => %{},
            "detected_languages" => [%{"language" => "fr", "confidence" => 0.9}]
          })
        )
      end)

      assert {:ok, meta} =
               ExtractedText.transform(@pdf, Path.join(tmp_dir, "fr.md"), [])

      assert meta == %{content_type: "text/markdown", word_count: 1, language: "fr"}
    end

    test "rejects unknown formats without calling the sidecar", %{tmp_dir: tmp_dir} do
      assert {:error, {:invalid_format, message}} =
               ExtractedText.transform(@pdf, Path.join(tmp_dir, "x.md"), format: :yaml)

      assert message =~ ":yaml"
    end

    test "converts sidecar errors", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transport_error, _message}} =
               ExtractedText.transform(@pdf, Path.join(tmp_dir, "x.md"), [])
    end
  end

  describe "Transcript.accept?/1" do
    test "accepts audio and video" do
      assert Transcript.accept?("audio/mpeg")
      assert Transcript.accept?("audio/wav")
      assert Transcript.accept?("video/mp4; codecs=avc1")
      refute Transcript.accept?("application/pdf")
      refute Transcript.accept?(nil)
    end
  end

  describe "Transcript.transform/3" do
    @describetag :tmp_dir

    test "sends the default transcription config and writes plain text", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)

        assert config == %{
                 "transcription" => %{
                   "enabled" => true,
                   "model" => "tiny",
                   "timestamps" => false
                 }
               }

        Req.Test.json(
          conn,
          envelope(%{
            "content" => "a steady tone",
            "metadata" => %{"transcription" => %{"language" => "en"}}
          })
        )
      end)

      dest = Path.join(tmp_dir, "transcript.txt")

      assert {:ok, meta} = Transcript.transform(@wav, dest, [])
      assert meta == %{content_type: "text/plain", model: "tiny", language: "en"}
      assert File.read!(dest) == "a steady tone"
    end

    test "translates :model, :language, :max_duration_ms and :timeout", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)

        assert config == %{
                 "transcription" => %{
                   "enabled" => true,
                   "model" => "base",
                   "timestamps" => false,
                   "language" => "de",
                   "max_duration_ms" => 30_000
                 },
                 "extraction_timeout_secs" => 600
               }

        Req.Test.json(conn, envelope(%{"content" => "hallo", "metadata" => %{}}))
      end)

      assert {:ok, %{model: "base", language: "de"}} =
               Transcript.transform(@wav, Path.join(tmp_dir, "t.txt"),
                 model: :base,
                 language: "de",
                 max_duration_ms: 30_000,
                 timeout: 600
               )
    end

    test "writes JSON with segments when timestamps: true", %{tmp_dir: tmp_dir} do
      segments = [
        %{"start_ms" => 0, "end_ms" => 1200, "text" => "a steady"},
        %{"start_ms" => 1200, "end_ms" => 2400, "text" => "tone"}
      ]

      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)
        assert config["transcription"]["timestamps"] == true

        Req.Test.json(
          conn,
          envelope(%{
            "content" => "a steady tone",
            "metadata" => %{"transcription" => %{"language" => "en"}},
            "segments" => segments
          })
        )
      end)

      dest = Path.join(tmp_dir, "transcript.json")

      assert {:ok, %{content_type: "application/json"}} =
               Transcript.transform(@wav, dest, timestamps: true)

      assert dest |> File.read!() |> Jason.decode!() == %{
               "content" => "a steady tone",
               "segments" => segments,
               "language" => "en"
             }
    end

    test "writes the configured language into the JSON when the sidecar reports none",
         %{tmp_dir: tmp_dir} do
      # Regression: the written JSON said `"language": null` while the returned
      # metadata said "de" — render resolved the language without the caller's opts.
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {conn, config} = config_from(conn)
        assert config["transcription"]["language"] == "de"

        Req.Test.json(conn, envelope(%{"content" => "hallo", "metadata" => %{}}))
      end)

      dest = Path.join(tmp_dir, "transcript.json")

      assert {:ok, %{content_type: "application/json", language: "de"}} =
               Transcript.transform(@wav, dest, timestamps: true, language: "de")

      assert %{"language" => "de"} = dest |> File.read!() |> Jason.decode!()
    end

    test "converts unsupported-format envelope errors", %{tmp_dir: tmp_dir} do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, error_envelope("unsupported_format", "Unsupported format: audio/wav"))
      end)

      assert {:error, {:unsupported_format, message}} =
               Transcript.transform(@wav, Path.join(tmp_dir, "t.txt"), [])

      assert message =~ "audio/wav"
    end
  end
end
