defmodule Camerex.Parser.Layers do
  @moduledoc """
  Agrupa as 18 classes ATR do parser em camadas semânticas (pele, cabelo,
  boné/chapéu, roupa, acessórios), cada uma com uma cor default, e extrai a
  máscara binária de uma camada suavizando as bordas em escada do upsample
  (close 5×5). O boné (Hat, classe 1) fica separado do cabelo (classe 2) — o
  modelo os distingue, então um boné não vira "cabelo colorido".
  """

  alias Camerex.Neon.Palette

  @groups [
    %{key: :skin, label: "pele", ids: [11, 12, 13, 14, 15], default: {255, 170, 120}},
    %{key: :hair, label: "cabelo", ids: [2], default: {255, 90, 30}},
    %{key: :hat, label: "boné/chapéu", ids: [1], default: {255, 205, 50}},
    %{key: :clothing, label: "roupa", ids: [4, 5, 6, 7, 8, 17], default: {43, 196, 178}},
    %{key: :accessories, label: "acessórios", ids: [3, 9, 10, 16], default: {127, 119, 240}}
  ]

  @type group :: %{key: atom(), label: String.t(), ids: [0..17], default: Palette.color()}

  @doc "As 4 camadas semânticas, na ordem de composição (pele → acessórios)."
  @spec groups() :: [group()]
  def groups, do: @groups

  @doc "Cores default por camada, no formato `%{skin: rgb, hair: rgb, ...}`."
  @spec default_colors() :: %{atom() => Palette.color()}
  def default_colors, do: Map.new(@groups, &{&1.key, &1.default})

  @doc """
  Normaliza cores por camada vindas do manifest/UI (`%{"skin" => [r,g,b]}` ou
  `%{skin: {r,g,b}}`) para `%{atom => {r,g,b}}`, mescladas sobre os defaults.
  `nil` devolve os defaults.
  """
  @spec normalize_colors(map() | nil) :: %{atom() => Palette.color()}
  def normalize_colors(nil), do: default_colors()

  def normalize_colors(map) when is_map(map) do
    parsed = Map.new(map, fn {k, v} -> {to_key(k), to_color(v)} end)
    Map.merge(default_colors(), parsed)
  end

  defp to_key(k) when is_atom(k), do: k
  defp to_key(k) when is_binary(k), do: String.to_existing_atom(k)
  defp to_color({r, g, b}), do: {r, g, b}
  defp to_color([r, g, b]), do: {r, g, b}

  @min_part_px 100

  @doc """
  Sugere uma cor por camada detectada da imagem: a cor média real de cada
  parte, **realçada para neon** (matiz preservado, saturação/brilho altos).
  Partes ausentes (ou minúsculas) caem no default. Deixa os pickers já
  coerentes com o que a pessoa veste.
  """
  @spec suggest_colors(Nx.Tensor.t(), Nx.Tensor.t()) :: %{atom() => Palette.color()}
  def suggest_colors(rgb, labels) do
    rgb_f = Nx.as_type(rgb, :f32)
    Map.new(@groups, fn g -> {g.key, suggest_one(rgb_f, labels, g)} end)
  end

  defp suggest_one(rgb_f, labels, group) do
    on =
      Enum.reduce(group.ids, Nx.broadcast(Nx.u8(0), Nx.shape(labels)), fn id, acc ->
        Nx.logical_or(acc, Nx.equal(labels, id))
      end)

    cnt = on |> Nx.sum() |> Nx.to_number()

    if cnt < @min_part_px do
      group.default
    else
      [r, g, b] =
        rgb_f
        |> Nx.multiply(Nx.new_axis(on, -1))
        |> Nx.sum(axes: [0, 1])
        |> Nx.divide(cnt)
        |> Nx.to_list()

      neon_boost({round(r), round(g), round(b)})
    end
  end

  # cor real → neon vívido: preserva o matiz, força saturação e brilho altos
  defp neon_boost({r, g, b}) do
    {h, s, v} = rgb_to_hsv(r, g, b)
    hsv_to_rgb(h, min(max(s, 0.55), 0.95), max(v, 0.9))
  end

  defp rgb_to_hsv(r, g, b) do
    r = r / 255
    g = g / 255
    b = b / 255
    mx = Enum.max([r, g, b])
    mn = Enum.min([r, g, b])
    d = mx - mn

    h =
      cond do
        d == 0 -> 0.0
        mx == r -> 60 * :math.fmod((g - b) / d, 6)
        mx == g -> 60 * ((b - r) / d + 2)
        true -> 60 * ((r - g) / d + 4)
      end

    {if(h < 0, do: h + 360, else: h), if(mx == 0, do: 0.0, else: d / mx), mx}
  end

  defp hsv_to_rgb(h, s, v) do
    c = v * s
    x = c * (1 - abs(:math.fmod(h / 60, 2) - 1))
    m = v - c

    {r, g, b} =
      cond do
        h < 60 -> {c, x, 0}
        h < 120 -> {x, c, 0}
        h < 180 -> {0, c, x}
        h < 240 -> {0, x, c}
        h < 300 -> {x, 0, c}
        true -> {c, 0, x}
      end

    {round((r + m) * 255), round((g + m) * 255), round((b + m) * 255)}
  end

  @doc """
  Máscara u8 `{h, w}` 0|255 dos pixels cujo rótulo está em `ids`, com close
  morfológico 5×5 para suavizar as bordas em escada deixadas pelo upsample.
  """
  @spec mask(Nx.Tensor.t(), [0..17]) :: Nx.Tensor.t()
  def mask(labels, ids) do
    ids
    |> Enum.reduce(Nx.broadcast(Nx.u8(0), Nx.shape(labels)), fn id, acc ->
      Nx.logical_or(acc, Nx.equal(labels, id))
    end)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
    |> Evision.Mat.from_nx()
    |> Evision.morphologyEx(Evision.Constant.cv_MORPH_CLOSE(), kernel(5))
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end

  defp kernel(s), do: Evision.Mat.from_nx(Nx.broadcast(Nx.u8(1), {s, s}))
end
