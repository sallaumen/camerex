# Spike 0.6: Ortex carrega u2net.onnx e devolve 7 outputs com shape esperado?
# Rodar: mix run scripts/spikes/ortex_smoke.exs

model_path = Path.expand("priv/models/u2net.onnx")

unless File.exists?(model_path) do
  IO.puts("FAIL: #{model_path} ausente — rode `mix camerex.setup` antes")
  System.halt(1)
end

model = Ortex.load(model_path)
input = Nx.broadcast(Nx.tensor(0.5, type: :f32), {1, 3, 320, 320})

{micros, output} = :timer.tc(fn -> Ortex.run(model, input) end)

n_outputs = tuple_size(output)
# backend_transfer traz o tensor do runtime do Ortex para a BEAM (contrato §7)
d0 = output |> elem(0) |> Nx.backend_transfer()
shape = Nx.shape(d0)

IO.puts("outputs: #{n_outputs} (esperado 7)")
IO.puts("shape do output 0: #{inspect(shape)} (esperado {1, 1, 320, 320})")
IO.puts("inferência: #{div(micros, 1000)} ms")

if n_outputs == 7 and shape == {1, 1, 320, 320} do
  IO.puts("PASS")
else
  IO.puts("FAIL")
  System.halt(1)
end
