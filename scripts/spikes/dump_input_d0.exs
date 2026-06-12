# Debug fase 1 (experimento cruzado): dump do input pré-processado em Elixir e
# do d0 do Ortex, em f32 little-endian cru, para comparação no Python.
# Rodar: mix run scripts/spikes/dump_input_d0.exs

defmodule DumpInputD0 do
  @model_path Path.expand("priv/models/u2net.onnx")
  @img_path Path.expand("exemplos/entrada/casal.jpg")

  @mean [0.485, 0.456, 0.406]
  @std [0.229, 0.224, 0.225]

  def run do
    rgb =
      @img_path
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())

    input = preprocess(rgb)
    # captura os bytes ANTES do Ortex.run: o buffer EXLA é doado na inferência
    input_bin = Nx.to_binary(Nx.as_type(input, :f32))

    model = Ortex.load(@model_path)
    d0 = Ortex.run(model, input) |> elem(0) |> Nx.backend_transfer()

    File.write!("/tmp/ex_input.bin", input_bin)
    File.write!("/tmp/ex_d0.bin", Nx.to_binary(Nx.as_type(d0, :f32)))

    IO.puts("ok: /tmp/ex_input.bin {1,3,320,320} f32 LE")
    IO.puts("ok: /tmp/ex_d0.bin    {1,1,320,320} f32 LE")
  end

  defp preprocess(rgb_mat) do
    t =
      rgb_mat
      |> Evision.resize({320, 320}, interpolation: Evision.Constant.cv_INTER_LANCZOS4())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)
      |> Nx.as_type(:f32)

    t = Nx.divide(t, Nx.max(Nx.reduce_max(t), 1.0e-6))

    t
    |> Nx.subtract(Nx.tensor(@mean))
    |> Nx.divide(Nx.tensor(@std))
    |> Nx.transpose(axes: [2, 0, 1])
    |> Nx.new_axis(0)
  end
end

DumpInputD0.run()
