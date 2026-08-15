defmodule AshStorageXberg.ResultTest do
  @moduledoc """
  The envelope and field readers shared by the analyzers and the variants.

  These used to be written twice — once in `AshStorageXberg.Analyzers`, once in
  `AshStorageXberg.Variants` — and the two copies disagreed. The point of these
  tests is that there is now exactly one answer per question. The call sites are
  covered in `AshStorageXberg.AnalyzersTest` and `AshStorageXberg.VariantsTest`.
  """
  use ExUnit.Case, async: true

  alias AshStorageXberg.Result

  # A non-breaking space is ordinary in extracted PDF and Office text. An
  # ASCII-only \s does not match it, so it glues the words either side into one.
  @nbsp_text "one\u00A0two three"

  describe "word_count/1" do
    test "splits on Unicode whitespace, not just ASCII" do
      assert Result.word_count(@nbsp_text) == 3
      assert Result.word_count("ideographic\u3000space") == 2
    end

    test "ignores leading, trailing and repeated whitespace" do
      assert Result.word_count("  a \n\n b  ") == 2
      assert Result.word_count("") == 0
    end
  end

  describe "declared_language/1" do
    test "reads metadata.language" do
      assert Result.declared_language(%{"metadata" => %{"language" => "deu"}}) == "deu"
    end

    test "ignores a non-string value rather than letting it reach blob metadata" do
      assert Result.declared_language(%{"metadata" => %{"language" => %{"code" => "deu"}}}) == nil
      assert Result.declared_language(%{"metadata" => %{}}) == nil
      assert Result.declared_language(%{}) == nil
    end
  end

  describe "detected_language/1" do
    test "accepts a bare code at the top level or under metadata" do
      assert Result.detected_language(%{"detected_languages" => ["eng", "deu"]}) == "eng"

      assert Result.detected_language(%{"metadata" => %{"detected_languages" => ["fra"]}}) ==
               "fra"
    end

    test "accepts object entries under any of the code keys" do
      assert Result.detected_language(%{"detected_languages" => [%{"language" => "eng"}]}) ==
               "eng"

      assert Result.detected_language(%{"detected_languages" => [%{"code" => "deu"}]}) == "deu"

      assert Result.detected_language(%{"detected_languages" => [%{"iso_code" => "fra"}]}) ==
               "fra"
    end

    test "is nil when there is nothing to read" do
      assert Result.detected_language(%{"detected_languages" => []}) == nil
      assert Result.detected_language(%{}) == nil
    end
  end

  describe "metadata readers" do
    test "default to an empty map rather than nil" do
      assert Result.metadata(%{}) == %{}
      assert Result.format_metadata(%{"metadata" => %{}}) == %{}
      assert Result.additional(%{}) == %{}
      assert Result.content(%{}) == ""
    end

    test "read through metadata" do
      result = %{
        "content" => "hi",
        "metadata" => %{"format" => %{"width" => 3}, "additional" => %{"codec" => "mp3"}}
      }

      assert Result.format_metadata(result) == %{"width" => 3}
      assert Result.additional(result) == %{"codec" => "mp3"}
      assert Result.content(result) == "hi"
    end
  end

  describe "first_value/2" do
    test "returns the value of the first key that is present" do
      assert Result.first_value(%{"b" => 2}, ["a", "b", "c"]) == 2
      assert Result.first_value(%{"a" => 1, "b" => 2}, ["a", "b"]) == 1
    end

    test "treats only nil as absent, so a false value survives" do
      assert Result.first_value(%{"a" => false}, ["a", "b"]) == false
      assert Result.first_value(%{"a" => nil, "b" => 0}, ["a", "b"]) == 0
      assert Result.first_value(%{}, ["a"]) == nil
    end
  end

  describe "first/1" do
    test "unwraps the first result" do
      assert Result.first({:ok, %{"results" => [%{"content" => "hi"}]}}) ==
               {:ok, %{"content" => "hi"}}
    end

    test "maps a per-file envelope error to the analyzer/variant error shape" do
      envelope = %{
        "results" => [],
        "errors" => [%{"error_type" => "ParsingError", "message" => "bad pdf"}]
      }

      assert Result.first({:ok, envelope}) == {:error, {:parsing_error, "bad pdf"}}
    end

    test "maps an unknown error type to a finite fallback" do
      envelope = %{"errors" => [%{"error_type" => "Whatever", "message" => "nope"}]}

      assert Result.first({:ok, envelope}) == {:error, {:unknown_error, "nope"}}
    end

    test "supplies a message when the envelope error carries none" do
      assert {:error, {:unknown_error, message}} =
               Result.first({:ok, %{"errors" => [%{"error_type" => "Whatever"}]}})

      assert message == "xberg extraction failed"
    end

    test "flattens the transport error tuple" do
      assert Result.first({:error, :timeout, "took too long"}) ==
               {:error, {:timeout, "took too long"}}
    end

    test "reports an envelope carrying neither results nor errors" do
      assert {:error, {:invalid_response, message}} = Result.first({:ok, %{"summary" => %{}}})
      assert message =~ "unexpected xberg envelope"
    end
  end

  describe "compact/1" do
    test "drops nil values and keeps false" do
      assert Result.compact(%{a: 1, b: nil, c: false}) == %{a: 1, c: false}
    end
  end
end
