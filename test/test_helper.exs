backend =
  case System.get_env("XBERG_BACKEND", "rest") do
    "rest" -> AshStorageXberg.XbergApi
    "nif" -> Xberg
    other -> raise("Unsupported XBERG_BACKEND=#{inspect(other)}. Use \"rest\" or \"nif\".")
  end

Application.put_env(:ash_storage_xberg, :xberg, backend)

# Tests warm the format cache repeatedly; keep its info/debug chatter out of the
# suite output while still surfacing warnings.
Logger.configure(level: :warning)

ExUnit.start(exclude: [:integration, :transcript])
