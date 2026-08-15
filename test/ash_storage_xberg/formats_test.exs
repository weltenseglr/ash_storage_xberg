defmodule AshStorageXberg.FormatsTest do
  @moduledoc """
  The cached `GET /formats` lookup behind every `accept?/1`.

  The invariant that matters here is that a lookup never raises and never
  escapes to the network mid-attach — `accept?/1` runs inside attach flows.
  """
  use ExUnit.Case, async: false

  alias AshStorageXberg.Formats

  setup do
    Application.put_env(:ash_storage_xberg, :req_options,
      plug: {Req.Test, AshStorageXberg.XbergApi},
      retry: false
    )

    Formats.reset()

    on_exit(fn ->
      Application.delete_env(:ash_storage_xberg, :req_options)
      Formats.reset()
    end)

    :ok
  end

  describe "reset/0" do
    test "returns :ok whether or not anything was cached" do
      # `:persistent_term.erase/1` returns false for an uncached key; that used
      # to leak out as reset/0's return value, contradicting its @spec.
      assert Formats.reset() == :ok

      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, [%{"extension" => "pdf", "mime_type" => "application/pdf"}])
      end)

      _ = Formats.mime_types()

      assert Formats.reset() == :ok
      assert Formats.reset() == :ok
    end

    test "makes the next lookup re-fetch" do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, [%{"extension" => "pdf", "mime_type" => "application/pdf"}])
      end)

      assert Formats.supported?("application/pdf")
      refute Formats.supported?("image/png")

      Formats.reset()

      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, [%{"extension" => "png", "mime_type" => "image/png"}])
      end)

      assert Formats.supported?("image/png")
      refute Formats.supported?("application/pdf")
    end
  end

  describe "supported?/1" do
    setup do
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn ->
        Req.Test.json(conn, [%{"extension" => "pdf", "mime_type" => "Application/PDF"}])
      end)

      :ok
    end

    test "normalizes parameters and casing on both sides of the comparison" do
      assert Formats.supported?("application/pdf")
      assert Formats.supported?("APPLICATION/PDF")
      assert Formats.supported?("application/pdf; charset=binary")
      assert Formats.supported?("  application/pdf  ")
    end

    test "is false for nil and for unknown types" do
      refute Formats.supported?(nil)
      refute Formats.supported?("application/x-nonsense")
    end
  end

  describe "fallback list" do
    test "is used when the backend is unreachable, and never raises" do
      Req.Test.stub(AshStorageXberg.XbergApi, &Req.Test.transport_error(&1, :econnrefused))

      assert Formats.supported?("application/pdf")
      assert Formats.supported?("text/plain")
    end

    test "is used when the backend reports an empty format list" do
      # An empty list used to be cached as a valid answer, so every accept?/1
      # rejected everything until the node restarted. Treat it as a failure.
      Req.Test.stub(AshStorageXberg.XbergApi, fn conn -> Req.Test.json(conn, []) end)

      assert Formats.supported?("application/pdf")
      assert Formats.supported?("text/plain")
    end

    test "claims nothing the sidecar does not actually report" do
      # A fallback that over-claims makes accept?/1 accept work extraction then
      # rejects. These two were listed but are not in the live /formats output;
      # xberg reports application/xml and audio/wav instead.
      Req.Test.stub(AshStorageXberg.XbergApi, &Req.Test.transport_error(&1, :econnrefused))

      refute Formats.supported?("text/xml")
      refute Formats.supported?("audio/x-wav")
      assert Formats.supported?("application/xml")
      assert Formats.supported?("audio/wav")
    end
  end
end
