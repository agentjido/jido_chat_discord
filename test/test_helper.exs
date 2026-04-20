if Code.ensure_loaded?(Dotenvy) do
  cwd = File.cwd!()

  env_from_files =
    Dotenvy.source!([
      Path.absname(".env", cwd),
      Path.absname(".env.test", cwd)
    ])

  Enum.each(env_from_files, fn {key, value} ->
    if System.get_env(key) in [nil, ""] do
      System.put_env(key, value)
    end
  end)
end

ExUnit.start(exclude: [:live])
