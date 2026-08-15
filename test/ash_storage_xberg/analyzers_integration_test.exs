defmodule AshStorageXberg.AnalyzersIntegrationTest do
  @moduledoc """
  Runs every analyzer against a live xberg sidecar and the real fixtures.
  Excluded by default; run with:

      XBERG_URL=http://127.0.0.1:8000 mix test --include integration
  """
  use ExUnit.Case, async: false

  alias AshStorageXberg.Analyzers.Audio
  alias AshStorageXberg.Analyzers.ContentType
  alias AshStorageXberg.Analyzers.Document
  alias AshStorageXberg.Analyzers.Image
  alias AshStorageXberg.Analyzers.Text
  alias AshStorageXberg.Formats

  @moduletag :integration

  @pdf Path.expand("../support/fixtures/CELEX_12016P_TXT_DE_TXT.pdf", __DIR__)
  @png Path.expand("../support/fixtures/good-scan-example-d-619x1024.png", __DIR__)
  @docx Path.expand("../support/fixtures/fixture.docx", __DIR__)
  @wav Path.expand("../support/fixtures/testaudio_44100_test01_20s.wav", __DIR__)

  setup do
    # Talk to the real sidecar, and never inherit a format cache built from a
    # stub in another test file.
    Application.delete_env(:ash_storage_xberg, :req_options)
    Formats.reset()
    on_exit(&Formats.reset/0)
    :ok
  end

  describe "ContentType" do
    test "sniffs the real type of each fixture" do
      assert {:ok,
              %{"detected_content_type" => "application/pdf", "content_type_verified" => true}} =
               ContentType.analyze(@pdf, content_type: "application/pdf")

      assert {:ok, %{"detected_content_type" => "image/png"}} = ContentType.analyze(@png, [])

      assert {:ok,
              %{
                "detected_content_type" =>
                  "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
              }} = ContentType.analyze(@docx, [])
    end

    test "flags a mismatch between claimed and sniffed type" do
      assert {:ok, %{"detected_content_type" => "image/png", "content_type_verified" => false}} =
               ContentType.analyze(@png, content_type: "application/pdf")
    end
  end

  describe "Image" do
    test "reads the dimensions of good-scan-example-d-619x1024.png" do
      assert {:ok, result} = Image.analyze(@png, [])
      assert result == %{"width" => 619, "height" => 1024, "format" => "PNG", "exif" => %{}}
    end
  end

  describe "Audio" do
    test "accepts the WAV fixture" do
      assert Audio.accept?("audio/wav")
      assert Audio.accept?("audio/x-wav")
    end

    test "returns media metadata, or a clear error on builds without media support" do
      case Audio.analyze(@wav, []) do
        {:ok, metadata} ->
          assert is_map(metadata)

        {:error, {kind, message}} ->
          assert kind in [:transcription_error, :unsupported_format]
          assert String.contains?(message, ["Transcription", "Unsupported format"])
      end
    end
  end

  describe "Document" do
    test "reads DOCX core properties" do
      assert {:ok, result} = Document.analyze(@docx, [])
      assert result["title"] == "Fixture Title"
      assert result["authors"] == ["Fixture Author"]
      assert result["page_count"] == 1
    end

    test "reads the PDF page count" do
      assert {:ok, %{"page_count" => page_count} = result} = Document.analyze(@pdf, [])
      assert page_count >= 1
      assert is_map(result)
    end
  end

  describe "Text" do
    test "extracts PDF text with counts" do
      assert {:ok, result} = Text.analyze(@pdf, [])
      assert result["text"] =~ "CHARTA DER GRUNDRECHTE"
      assert result["word_count"] > 0
      assert result["ocr_used"] == false
      refute Map.has_key?(result, "text_truncated")
    end

    test "extracts DOCX text as markdown and honours :max_bytes" do
      assert {:ok, result} = Text.analyze(@docx, output: :markdown, max_bytes: 5)
      assert result["text"] == "Docx "
      assert result["text_truncated"] == true
      assert result["word_count"] == 4
    end

    test "detects the language of a longer text document" do
      path =
        Path.join(System.tmp_dir!(), "ash_storage_xberg_language_#{System.unique_integer()}.txt")

      File.write!(path, """
      The quick brown fox jumps over the lazy dog. This is a longer English
      paragraph used to exercise the language detection of the extraction
      service. It should be detected as English with high confidence.
      """)

      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{"language" => "eng"}} = Text.analyze(path, [])
    end

    test "only runs OCR when asked to" do
      assert {:ok, %{"ocr_used" => false}} = Text.analyze(@png, [])
      assert {:ok, %{"ocr_used" => true}} = Text.analyze(@png, ocr: true)
    end

    test "accept?/1 is backed by the live /formats list" do
      assert Text.accept?("application/pdf")
      assert Text.accept?("image/png")
      refute Text.accept?("application/x-does-not-exist")
    end
  end
end
