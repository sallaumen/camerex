defmodule Camerex.Pipeline.PhotoPropertyTest do
  @moduledoc """
  Invariantes dos cálculos PUROS de composição do `Photo` sobre cenas
  aleatórias — a rede de segurança pra refatorar a matemática do pipeline sem
  mudar comportamento. Roda no gate (não precisa de modelo: `render_with_labels`
  recebe os rótulos prontos).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Camerex.Pipeline.Photo

  @h 28
  @w 28

  property "bg_opacity nunca escurece e é monotônico (compõe por máximo)" do
    labels = labels()

    check all(bytes <- binary(length: @h * @w * 3), max_runs: 20) do
      rgb = scene(bytes)
      base = Photo.render_with_labels(rgb, labels, detail: 0.0, bg_opacity: 0.0)
      mid = Photo.render_with_labels(rgb, labels, detail: 0.0, bg_opacity: 0.3)
      high = Photo.render_with_labels(rgb, labels, detail: 0.0, bg_opacity: 0.7)

      # o original entra por max(neon, original×op): subir a opacidade só pode
      # ACENDER pixels (nunca escurecer), e é monótono na opacidade
      assert all_ge?(mid, base), "bg 0.3 ficou mais escuro que bg 0"
      assert all_ge?(high, mid), "bg 0.7 ficou mais escuro que bg 0.3"
    end
  end

  property "bg_opacity 0.0 é identidade (não toca o neon)" do
    labels = labels()

    check all(bytes <- binary(length: @h * @w * 3), max_runs: 15) do
      rgb = scene(bytes)
      sem = Photo.render_with_labels(rgb, labels, detail: 0.0)
      zero = Photo.render_with_labels(rgb, labels, detail: 0.0, bg_opacity: 0.0)

      assert all_eq?(zero, sem), "bg_opacity 0.0 alterou a saída"
    end
  end

  property "transparent_bg: RGBA com RGB intacto e alpha = máximo dos canais" do
    labels = labels()

    check all(bytes <- binary(length: @h * @w * 3), max_runs: 20) do
      rgb = scene(bytes)
      opaque = Photo.render_with_labels(rgb, labels, detail: 0.0)
      transp = Photo.render_with_labels(rgb, labels, detail: 0.0, transparent_bg: true)

      assert Nx.shape(transp) == {@h, @w, 4}
      # ligar a transparência só ANEXA alpha — não mexe no RGB
      assert all_eq?(transp[[.., .., 0..2]], opaque), "RGB mudou ao ligar transparência"
      # alpha = brilho do conteúdo (máximo dos 3 canais)
      assert all_eq?(transp[[.., .., 3]], Nx.reduce_max(opaque, axes: [2])),
             "alpha != máximo dos canais"
    end
  end

  # rótulos sintéticos: bloco de roupa (4) no centro, resto fundo (0) — há área
  # de FUNDO onde o original esmaecido/transparência se manifestam.
  defp labels do
    rows = Nx.iota({@h, @w}, axis: 0)
    cols = Nx.iota({@h, @w}, axis: 1)

    block =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 8), Nx.less(rows, 20)),
        Nx.logical_and(Nx.greater_equal(cols, 8), Nx.less(cols, 20))
      )

    Nx.select(block, Nx.u8(4), Nx.u8(0))
  end

  defp scene(bytes) do
    bytes |> Nx.from_binary(:u8, backend: Nx.BinaryBackend) |> Nx.reshape({@h, @w, 3})
  end

  defp all_ge?(a, b), do: a |> Nx.greater_equal(b) |> Nx.all() |> Nx.to_number() == 1
  defp all_eq?(a, b), do: a |> Nx.equal(b) |> Nx.all() |> Nx.to_number() == 1
end
