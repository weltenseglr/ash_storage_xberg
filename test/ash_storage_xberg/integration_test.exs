defmodule AshStorageXberg.IntegrationTest do
  @moduledoc """
  Round-trips against a live xberg sidecar. Excluded by default; run with:

      XBERG_URL=http://127.0.0.1:8000 mix test --include integration
  """
  use ExUnit.Case, async: false

  alias AshStorageXberg.XbergApi

  @moduletag :integration

  @fixture Path.expand("../support/fixtures/CELEX_12016P_TXT_DE_TXT.pdf", __DIR__)

  test "health" do
    assert {:ok, %{"status" => "healthy"}} = XbergApi.health()
  end

  test "extracts a local PDF via multipart" do
    assert {:ok, %{"results" => [result], "summary" => %{"errors" => 0}}} =
             XbergApi.extract(
               input: %{uri: @fixture},
               config: %{output_format: "markdown"}
             )

    assert result["content"] =~ "CHARTA DER GRUNDRECHTE"
    assert result["mime_type"] == "application/pdf"
    assert result["metadata"]["format"]["page_count"] >= 1
  end

  test "extracts bytes with the NIF input shape" do
    assert {:ok, %{"results" => [result]}} =
             XbergApi.extract(
               input: %{
                 kind: :bytes,
                 bytes: File.read!(@fixture),
                 filename: "CELEX_12016P_TXT_DE_TXT.pdf",
                 mime_type: "application/pdf"
               }
             )

    assert result["content"] =~ "CHARTA DER GRUNDRECHTE"
  end

  test "detects MIME type without extraction" do
    assert {:ok, %{"mime_type" => "application/pdf"}} = XbergApi.detect(@fixture)
  end

  test "lists supported formats" do
    formats = XbergApi.list_supported_formats()
    assert Enum.any?(formats, &(&1["extension"] == "pdf"))
    assert Enum.any?(formats, &(&1["extension"] == "docx"))
  end

  test "returns the NIF error tuple for invalid config" do
    assert {:error, :validation_error, message} =
             XbergApi.extract(input: %{uri: @fixture}, config: "{broken json")

    assert message =~ "JSON"
  end
end
