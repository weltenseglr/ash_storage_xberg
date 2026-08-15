defmodule AshStorageXberg.VariantsIntegrationTest do
  @moduledoc """
  Variant round-trips against a live xberg sidecar. Excluded by default; run with:

      XBERG_URL=http://127.0.0.1:8000 mix test --include integration
  """
  use ExUnit.Case, async: false

  alias AshStorageXberg.Variants.ExtractedText
  alias AshStorageXberg.Variants.PageThumbnail

  @moduletag :integration
  @moduletag :tmp_dir

  @pdf Path.expand("../support/fixtures/CELEX_12016P_TXT_DE_TXT.pdf", __DIR__)

  @png_magic <<0x89, ?P, ?N, ?G, ?\r, ?\n, 0x1A, ?\n>>

  describe "PageThumbnail" do
    test "renders the first page of a PDF to PNG", %{tmp_dir: tmp_dir} do
      dest = Path.join(tmp_dir, "thumb.png")

      assert {:ok, meta} = PageThumbnail.transform(@pdf, dest, dpi: 72)
      assert meta.content_type == "image/png"
      assert meta.page == 1
      assert is_integer(meta.width) and meta.width > 0
      assert is_integer(meta.height) and meta.height > 0

      raster = File.read!(dest)
      assert byte_size(raster) > 0
      assert <<@png_magic, _rest::binary>> = raster
    end

    test "renders to WebP when asked", %{tmp_dir: tmp_dir} do
      dest = Path.join(tmp_dir, "thumb.webp")

      assert {:ok, %{content_type: "image/webp"}} =
               PageThumbnail.transform(@pdf, dest, format: :webp)

      assert <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>> = File.read!(dest)
    end

    test "reports a missing page", %{tmp_dir: tmp_dir} do
      assert {:error, {:no_page_raster, message}} =
               PageThumbnail.transform(@pdf, Path.join(tmp_dir, "p100.png"), page: 100)

      assert message =~ "page 100"
    end

    test "accepts PDFs and rejects audio" do
      assert PageThumbnail.accept?("application/pdf")
      refute PageThumbnail.accept?("audio/wav")
    end
  end

  describe "ExtractedText" do
    test "writes the markdown text of a PDF", %{tmp_dir: tmp_dir} do
      dest = Path.join(tmp_dir, "hello.md")

      assert {:ok, meta} = ExtractedText.transform(@pdf, dest, [])
      assert meta.content_type == "text/markdown"
      assert meta.word_count > 0
      assert meta.ocr_used == false

      assert File.read!(dest) =~ "CHARTA DER GRUNDRECHTE"
    end

    test "writes a JSON document with metadata and tables", %{tmp_dir: tmp_dir} do
      dest = Path.join(tmp_dir, "hello.json")

      assert {:ok, %{content_type: "application/json"}} =
               ExtractedText.transform(@pdf, dest, format: :json, timeout: 60)

      assert %{"content" => content, "metadata" => metadata, "tables" => tables} =
               dest |> File.read!() |> Jason.decode!()

      assert content =~ "CHARTA DER GRUNDRECHTE"
      assert metadata["format"]["page_count"] >= 1
      assert is_list(tables)
    end

    test "accept?/1 is driven by the sidecar's format list" do
      AshStorageXberg.Formats.reset()
      on_exit(&AshStorageXberg.Formats.reset/0)

      assert ExtractedText.accept?("application/pdf")
      assert ExtractedText.accept?("text/markdown")
      refute ExtractedText.accept?("application/x-nonsense")
    end
  end
end

defmodule AshStorageXberg.VariantsTranscriptTest do
  @moduledoc """
  Live transcription round-trip. Needs an xberg build with the audio/Whisper
  feature and a cached model (`POST /cache/warm`), so it is excluded from every
  default run — including `--include integration`:

      XBERG_URL=http://127.0.0.1:8000 mix test --include transcript
  """
  use ExUnit.Case, async: false

  alias AshStorageXberg.Variants.Transcript

  @moduletag :transcript
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @wav Path.expand("../support/fixtures/testaudio_44100_test01_20s.wav", __DIR__)

  test "transcribes an audio file", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "transcript.txt")

    case Transcript.transform(@wav, dest, model: :tiny, timeout: 300) do
      {:ok, meta} ->
        assert meta.content_type == "text/plain"
        assert meta.model == "tiny"
        assert File.exists?(dest)

      {:error, {kind, message}} ->
        flunk(
          "the xberg sidecar could not transcribe #{@wav} (#{kind}: #{message}). " <>
            "Transcription requires a build with the audio/Whisper feature; " <>
            "xberg 1.0.14's stock image rejects audio input."
        )
    end
  end
end
