defmodule Camerex.CLI do
  @moduledoc """
  Parsing puro dos argumentos das tasks `mix camerex.foto` e
  `mix camerex.video` — testável sem Mix.
  """

  @photo_usage "uso: mix camerex.foto IN OUT [--halo 0..1] [--detail 0..1]"
  @video_usage "uso: mix camerex.video IN OUT"

  @type parsed :: %{input: String.t(), output: String.t(), opts: keyword()}

  @spec parse_photo([String.t()]) :: {:ok, parsed()} | {:error, String.t()}
  def parse_photo(argv) do
    parse(argv, [halo: :float, detail: :float], @photo_usage)
  end

  @spec parse_video([String.t()]) :: {:ok, parsed()} | {:error, String.t()}
  def parse_video(argv) do
    parse(argv, [], @video_usage)
  end

  defp parse(argv, switches, usage) do
    {opts, positional, invalid} = OptionParser.parse(argv, strict: switches)

    cond do
      invalid != [] ->
        names = Enum.map_join(invalid, ", ", fn {name, _value} -> name end)
        {:error, "opções inválidas: #{names}\n#{usage}"}

      length(positional) != 2 ->
        {:error, usage}

      true ->
        validate(opts, positional)
    end
  end

  defp validate(opts, [input, output]) do
    with :ok <- validate_unit(:halo, opts[:halo]),
         :ok <- validate_unit(:detail, opts[:detail]) do
      {:ok, %{input: input, output: output, opts: opts}}
    end
  end

  defp validate_unit(_key, nil), do: :ok
  defp validate_unit(_key, value) when value >= 0.0 and value <= 1.0, do: :ok
  defp validate_unit(key, value), do: {:error, "#{key} fora de [0,1]: #{value}"}
end
