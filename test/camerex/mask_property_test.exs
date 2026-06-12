defmodule Camerex.MaskPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Camerex.Mask

  @side 32
  @ema_alpha 0.45
  @bin_threshold 0.45

  property "área da máscara pós-EMA varia no máximo 30% entre frames consecutivos" do
    check all(
            flips_per_frame <-
              list_of(
                list_of({integer(0..(@side - 1)), integer(0..(@side - 1))}, max_length: 25),
                min_length: 2,
                max_length: 8
              )
          ) do
      base = base_mask_set()
      masks = Enum.map(flips_per_frame, &noisy_mask(base, &1))

      {areas, _final_ema} =
        Enum.map_reduce(masks, nil, fn mask, prev_ema ->
          ema =
            mask
            |> Nx.as_type(:f32)
            |> Nx.divide(255.0)
            |> Mask.ema(prev_ema, @ema_alpha)

          area = ema |> Nx.greater(@bin_threshold) |> Nx.sum() |> Nx.to_number()
          {area, ema}
        end)

      areas
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert b <= a * 1.3,
               "área cresceu mais de 30%: #{a} → #{b}"

        assert b >= a * 0.7,
               "área caiu mais de 30%: #{a} → #{b}"
      end)
    end
  end

  # retângulo central 16×16 (área 256) num grid 32×32
  defp base_mask_set do
    for y <- 8..23, x <- 8..23, into: MapSet.new(), do: {x, y}
  end

  # inverte (liga↔desliga) os pixels sorteados — ruído de segmentação simulado
  defp noisy_mask(base, flips) do
    on =
      flips
      |> Enum.uniq()
      |> Enum.reduce(base, fn p, acc ->
        if MapSet.member?(acc, p), do: MapSet.delete(acc, p), else: MapSet.put(acc, p)
      end)

    for y <- 0..(@side - 1) do
      for x <- 0..(@side - 1) do
        if MapSet.member?(on, {x, y}), do: 255, else: 0
      end
    end
    |> Nx.tensor(type: :u8)
  end
end
