defmodule AshStorageXberg.XbergApiTest do
  use ExUnit.Case, async: false

  alias AshStorageXberg.XbergApi

  @fixture Path.expand("../support/fixtures/CELEX_12016P_TXT_DE_TXT.pdf", __DIR__)

  @envelope %{
    "results" => [
      %{"content" => "Hello", "mime_type" => "application/pdf", "metadata" => %{}}
    ],
    "errors" => [],
    "summary" => %{"inputs" => 1, "results" => 1, "errors" => 0}
  }

  setup do
    Application.put_env(:ash_storage_xberg, :req_options,
      plug: {Req.Test, AshStorageXberg.XbergApi},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:ash_storage_xberg, :req_options) end)
    :ok
  end

  defp parse_multipart(conn) do
    opts = Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: 50_000_000)
    Plug.Parsers.call(conn, opts)
  end

  describe "extract/1 with local input" do
    test "streams a local file path as multipart and returns the envelope" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/extract"
        conn = parse_multipart(conn)
        assert %Plug.Upload{filename: "CELEX_12016P_TXT_DE_TXT.pdf"} = conn.params["files"]
        Req.Test.json(conn, @envelope)
      end)

      assert {:ok, %{"results" => [%{"content" => "Hello"}]}} =
               XbergApi.extract(input: %{uri: @fixture})
    end

    test "sends bytes with filename, mime_type, and config field" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        conn = parse_multipart(conn)

        assert %Plug.Upload{filename: "doc.pdf", content_type: "application/pdf"} =
                 conn.params["files"]

        assert Jason.decode!(conn.params["config"]) == %{"output_format" => "markdown"}
        Req.Test.json(conn, @envelope)
      end)

      assert {:ok, _} =
               XbergApi.extract(
                 input: %{bytes: "%PDF-1.4", filename: "doc.pdf", mime_type: "application/pdf"},
                 config: %{output_format: "markdown"}
               )
    end

    test "accepts NIF-style pre-encoded JSON binaries for input and config" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        conn = parse_multipart(conn)
        assert %Plug.Upload{filename: "x.bin"} = conn.params["files"]
        assert Jason.decode!(conn.params["config"]) == %{"force_ocr" => true}
        Req.Test.json(conn, @envelope)
      end)

      assert {:ok, _} =
               XbergApi.extract(
                 input: Jason.encode!(%{bytes: "abc", filename: "x.bin"}),
                 config: ~s({"force_ocr":true})
               )
    end

    test "merges per-input config over request config" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        conn = parse_multipart(conn)

        assert Jason.decode!(conn.params["config"]) ==
                 %{"output_format" => "plain", "force_ocr" => true}

        Req.Test.json(conn, @envelope)
      end)

      assert {:ok, _} =
               XbergApi.extract(
                 input: %{bytes: "abc", config: %{force_ocr: true}},
                 config: %{output_format: "plain", force_ocr: false}
               )
    end

    test "returns validation errors without calling the server" do
      assert {:error, :validation_error, "missing :input"} = XbergApi.extract([])

      assert {:error, :validation_error, message} =
               XbergApi.extract(input: %{uri: "/no/such/file.pdf"})

      assert message =~ "file not found"
    end
  end

  describe "extract/1 with remote URI (presigned URL flow)" do
    test "posts a JSON body so the sidecar fetches the URL directly" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        assert conn.request_path == "/extract"
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "inputs" => [%{"uri" => "https://bucket.example.com/key?sig=abc"}],
                 "config" => %{"output_format" => "markdown"}
               }

        Req.Test.json(conn, @envelope)
      end)

      assert {:ok, _} =
               XbergApi.extract(
                 input: %{uri: "https://bucket.example.com/key?sig=abc"},
                 config: %{output_format: "markdown"}
               )
    end

    test "omits the config key when no config is given" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"inputs" => [%{"uri" => "https://example.com/a.pdf"}]}
        Req.Test.json(conn, @envelope)
      end)

      assert {:ok, _} = XbergApi.extract(input: %{uri: "https://example.com/a.pdf"})
    end
  end

  describe "extract_batch/1" do
    test "sends multiple local files as repeated multipart parts" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        # Plug.Parsers collapses repeated field names, so count parts in the raw
        # body instead (the sidecar itself accepts repeated `files` fields).
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert length(String.split(body, ~s(name="files"))) == 3
        assert body =~ ~s(filename="CELEX_12016P_TXT_DE_TXT.pdf")
        assert body =~ ~s(filename="b.txt")
        Req.Test.json(conn, @envelope)
      end)

      assert {:ok, _} =
               XbergApi.extract_batch(
                 inputs: [%{uri: @fixture}, %{bytes: "abc", filename: "b.txt"}]
               )
    end

    test "sends all-remote batches as one JSON body" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{
                 "inputs" => [
                   %{"uri" => "https://a.example/1"},
                   %{"uri" => "https://a.example/2"}
                 ]
               } =
                 Jason.decode!(body)

        Req.Test.json(conn, @envelope)
      end)

      assert {:ok, _} =
               XbergApi.extract_batch(
                 inputs: [%{uri: "https://a.example/1"}, %{uri: "https://a.example/2"}]
               )
    end

    test "rejects mixed remote and local batches" do
      assert {:error, :validation_error, message} =
               XbergApi.extract_batch(inputs: [%{uri: "https://a.example/1"}, %{uri: @fixture}])

      assert message =~ "cannot mix"
    end

    test "rejects per-input config in multipart batches" do
      assert {:error, :validation_error, message} =
               XbergApi.extract_batch(inputs: [%{bytes: "a", config: %{force_ocr: true}}])

      assert message =~ "per-input config"
    end

    test "rejects an empty batch instead of posting an empty multipart" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        flunk("no request expected, got #{conn.request_path}")
      end)

      assert {:error, :validation_error, message} = XbergApi.extract_batch(inputs: [])
      assert message =~ "must not be empty"
    end
  end

  describe "error mapping" do
    test "maps the sidecar error envelope to the NIF three-tuple" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error_type" => "ValidationError",
          "message" => "Invalid extraction configuration",
          "status_code" => 400
        })
      end)

      assert {:error, :validation_error, "Invalid extraction configuration"} =
               XbergApi.extract(input: %{bytes: "abc"})
    end

    test "maps known parsing errors without interning response values" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"error_type" => "ParsingError", "message" => "bad pdf"})
      end)

      assert {:error, :parsing_error, "bad pdf"} = XbergApi.extract(input: %{bytes: "abc"})
    end

    test "maps unknown error types to a finite fallback" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error_type" => "AttackerControlledError", "message" => "failed"})
      end)

      assert {:error, :unknown_error, "failed"} = XbergApi.extract(input: %{bytes: "abc"})
    end

    test "maps transport failures" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :transport_error, _message} = XbergApi.extract(input: %{bytes: "abc"})
    end
  end

  describe "list_supported_formats/0" do
    test "returns the bare list, NIF-style" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, [%{"extension" => "pdf", "mime_type" => "application/pdf"}])
      end)

      assert [%{"extension" => "pdf"}] = XbergApi.list_supported_formats()
    end
  end

  describe "detect/1" do
    test "posts the file to /detect" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        assert conn.request_path == "/detect"

        Req.Test.json(conn, %{
          "mime_type" => "application/pdf",
          "filename" => "CELEX_12016P_TXT_DE_TXT.pdf"
        })
      end)

      assert {:ok, %{"mime_type" => "application/pdf"}} = XbergApi.detect(@fixture)
    end
  end

  describe "backend exchange" do
    test "normalizes NIF extraction results to the REST response shape" do
      assert AshStorageXberg.Xberg.impl() == AshStorageXberg.XbergApi

      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.FakeNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      assert {:ok,
              %{
                "results" => [
                  %{
                    "content" => "from nif",
                    "metadata" => %{
                      "ocr_used" => false,
                      "method" => "native",
                      "format" => %{
                        "format_type" => "pdf",
                        "page_count" => 2,
                        "pdf_version" => "1.7"
                      }
                    }
                  }
                ]
              }} =
               AshStorageXberg.Xberg.extract(input: %{uri: "x"})
    end

    test "normalizes NIF batch and supported-format results" do
      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.FakeNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      assert {:ok, %{"results" => [%{"status" => "complete", "warning" => nil}]}} =
               AshStorageXberg.Xberg.extract_batch(inputs: [%{uri: "x"}])

      assert [%{"extension" => "pdf", "mime_type" => "application/pdf"}] =
               AshStorageXberg.Xberg.list_supported_formats()
    end

    test "preserves backend errors" do
      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.FailingNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      assert {:error, :parsing_error, "bad pdf"} =
               AshStorageXberg.Xberg.extract(input: %{uri: "x"})

      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.UnsupportedNif)

      assert {:error, :unsupported_format, "Unsupported format: audio/x-wav"} =
               AshStorageXberg.Xberg.extract(input: %{uri: "x"})
    end

    test "canonicalizes local WAV inputs before backend dispatch" do
      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.InputNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      assert {:ok,
              %{
                "input" => %{
                  "filename" => "recording.wav",
                  "mime_type" => "audio/wav",
                  "uri" => "/tmp/recording.wav"
                }
              }} = AshStorageXberg.Xberg.extract(input: %{uri: "/tmp/recording.wav"})

      assert {:ok, %{"input" => %{"mime_type" => "audio/wav"}}} =
               AshStorageXberg.Xberg.extract(
                 input: %{uri: "/tmp/recording.wav", mime_type: "audio/x-wav"}
               )
    end

    # Regression: the facade and the REST client carried separate copies of the
    # scheme regex and disagreed about `file://`. The client treated it as local
    # (multipart), the facade treated it as remote and skipped canonicalization.
    test "canonicalizes file:// WAV inputs too" do
      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.InputNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      assert {:ok,
              %{
                "input" => %{
                  "filename" => "recording.wav",
                  "mime_type" => "audio/wav",
                  "uri" => "file:///tmp/recording.wav"
                }
              }} = AshStorageXberg.Xberg.extract(input: %{uri: "file:///tmp/recording.wav"})
    end

    test "leaves genuinely remote inputs alone" do
      Application.put_env(:ash_storage_xberg, :xberg, __MODULE__.InputNif)
      on_exit(fn -> Application.delete_env(:ash_storage_xberg, :xberg) end)

      assert {:ok, %{"input" => input}} =
               AshStorageXberg.Xberg.extract(input: %{uri: "https://example.test/recording.wav"})

      refute Map.has_key?(input, "filename")
      refute Map.has_key?(input, "mime_type")
    end
  end

  defmodule NativeResult do
    defstruct [:content, :metadata]
  end

  defmodule FakeNif do
    @behaviour AshStorageXberg.Xberg

    @impl true
    def extract(_opts) do
      {:ok,
       %{
         results: [
           %NativeResult{
             content: "from nif",
             metadata: %{
               ocr_used: false,
               method: :native,
               format: %{format_type: "pdf", pdf: %{page_count: 2, pdf_version: "1.7"}}
             }
           }
         ]
       }}
    end

    @impl true
    def extract_batch(_opts), do: {:ok, %{results: [%{status: :complete, warning: nil}]}}

    @impl true
    def list_supported_formats,
      do: [%{extension: "pdf", mime_type: "application/pdf"}]
  end

  defmodule FailingNif do
    @behaviour AshStorageXberg.Xberg

    @impl true
    def extract(_opts), do: {:error, :parsing_error, "bad pdf"}

    @impl true
    def extract_batch(_opts), do: {:error, :parsing_error, "bad batch"}

    @impl true
    def list_supported_formats, do: []
  end

  defmodule UnsupportedNif do
    @behaviour AshStorageXberg.Xberg

    @impl true
    def extract(_opts), do: {:error, "Unsupported format: audio/x-wav"}

    @impl true
    def extract_batch(_opts), do: {:error, "Unsupported format: audio/x-wav"}

    @impl true
    def list_supported_formats, do: []
  end

  defmodule InputNif do
    @behaviour AshStorageXberg.Xberg

    @impl true
    def extract(opts), do: {:ok, %{input: Keyword.fetch!(opts, :input)}}

    @impl true
    def extract_batch(opts), do: {:ok, %{inputs: Keyword.fetch!(opts, :inputs)}}

    @impl true
    def list_supported_formats, do: []
  end
end
