defmodule Camerex.Pipeline.PhotoTest do
  # usa Application.put_env (:fixture_mask_path)
  use ExUnit.Case, async: false

  alias Camerex.Pipeline.Photo

  @moduletag :tmp_dir

  @teal {43, 196, 178}

  defp gray_scene(h, w), do: Nx.broadcast(Nx.u8(127), {h, w, 3})

  defp count_color_pixels(out, {r, g, b}) do
    out
    |> Nx.equal(Nx.tensor([r, g, b], type: :u8))
    |> Nx.all(axes: [-1])
    |> Nx.sum()
    |> Nx.to_number()
  end

  test "mono: devolve {h, w, 3} u8 com pixels de linha na cor exata do preset" do
    assert {:ok, out} = Photo.render(gray_scene(32, 32), preset: "forro-teal")

    assert Nx.shape(out) == {32, 32, 3}
    assert Nx.type(out) == {:u, 8}
    assert count_color_pixels(out, @teal) > 0
  end

  test "render_with_mask reproduz render/2 dada a mesma máscara" do
    scene = gray_scene(48, 48)
    segmenter = Application.fetch_env!(:camerex, :segmenter)
    {:ok, raw} = segmenter.segment(scene, model: "u2net")
    mask = Camerex.Mask.largest_component(raw)

    opts = [preset: "miami", halo: 0.8, detail: 0.3]
    {:ok, integrado} = Photo.render(scene, opts)
    {:ok, separado} = Photo.render_with_mask(scene, mask, opts)

    assert Nx.equal(integrado, separado) |> Nx.all() |> Nx.to_number() == 1
  end

  test "preset desconhecido devolve erro" do
    assert {:error, {:unknown_preset, "vaporwave"}} =
             Photo.render(gray_scene(8, 8), preset: "vaporwave")
  end

  test "descarta componentes menores via largest_component", %{tmp_dir: tmp} do
    # máscara fixture 64x64: blob grande à esquerda + blob pequeno à direita
    rows = Nx.iota({64, 64}, axis: 0)
    cols = Nx.iota({64, 64}, axis: 1)

    big =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 8), Nx.less(rows, 56)),
        Nx.logical_and(Nx.greater_equal(cols, 4), Nx.less(cols, 28))
      )

    small =
      Nx.logical_and(
        Nx.logical_and(Nx.greater_equal(rows, 28), Nx.less(rows, 36)),
        Nx.logical_and(Nx.greater_equal(cols, 48), Nx.less(cols, 56))
      )

    mask = big |> Nx.logical_or(small) |> Nx.multiply(255) |> Nx.as_type(:u8)

    png = Path.join(tmp, "two_blobs.png")
    Evision.imwrite(png, Evision.Mat.from_nx(mask))
    Application.put_env(:camerex, :fixture_mask_path, png)
    on_exit(fn -> Application.delete_env(:camerex, :fixture_mask_path) end)

    assert {:ok, out} = Photo.render(gray_scene(64, 64), preset: "forro-teal")

    # a linha (cor exata) existe na imagem, mas NÃO na região do blob
    # pequeno — ele foi descartado; o halo que vaza para lá nunca atinge
    # a cor cheia
    assert count_color_pixels(out, @teal) > 0
    assert count_color_pixels(out[[24..39, 44..59]], @teal) == 0
  end

  describe "gradiente e bloom" do
    test "preset gradiente: base puxa mais para o vermelho que o topo" do
      {:ok, out} = Photo.render(gray_scene(40, 40), preset: "aurora")

      # fixture = retângulo central (rows 10..29); topo → teal (R 43),
      # base → coral (R 255), via vertical_weights sobre a bbox da máscara
      topo = out[[6..14, .., 0]] |> Nx.reduce_max() |> Nx.to_number()
      base = out[[25..33, .., 0]] |> Nx.reduce_max() |> Nx.to_number()
      assert base > topo
    end

    test "bloom muda o resultado; ausência de bloom é o padrão de hoje" do
      scene = gray_scene(40, 40)

      {:ok, sem} = Photo.render(scene, preset: "forro-teal")
      {:ok, com} = Photo.render(scene, preset: "forro-teal", bloom: 0.9)

      refute Nx.to_binary(sem) == Nx.to_binary(com)
    end

    test "chroma muda o resultado; ausência de chroma é o padrão de hoje" do
      # cena com contraste de cor (quadrado saturado) sob máscara cheia
      rows = Nx.iota({40, 40}, axis: 0)
      cols = Nx.iota({40, 40}, axis: 1)

      inside =
        Nx.logical_and(
          Nx.logical_and(Nx.greater_equal(rows, 12), Nx.less(rows, 28)),
          Nx.logical_and(Nx.greater_equal(cols, 12), Nx.less(cols, 28))
        )

      bg = Nx.tensor([81, 81, 81], type: :u8) |> Nx.broadcast({40, 40, 3})
      sq = Nx.tensor([200, 30, 30], type: :u8) |> Nx.broadcast({40, 40, 3})
      scene = Nx.select(Nx.new_axis(inside, -1) |> Nx.broadcast({40, 40, 3}), sq, bg)

      {:ok, sem} = Photo.render(scene, preset: "forro-teal")
      {:ok, com} = Photo.render(scene, preset: "forro-teal", chroma: 0.8)

      refute Nx.to_binary(sem) == Nx.to_binary(com)
    end
  end

  describe "chão (Neon.Scene)" do
    test "floor: true anexa o piso (mais alto); floor: false não muda as dims" do
      rgb = gray_scene(40, 40)
      rows = Nx.iota({40, 40}, axis: 0)

      mask =
        Nx.logical_and(Nx.greater_equal(rows, 5), Nx.less(rows, 38))
        |> Nx.multiply(255)
        |> Nx.as_type(:u8)

      {:ok, flat} = Photo.render_with_mask(rgb, mask, preset: "forro-teal", floor: false)
      {:ok, floored} = Photo.render_with_mask(rgb, mask, preset: "forro-teal", floor: true)

      assert Nx.shape(flat) == {40, 40, 3}
      assert elem(Nx.shape(floored), 0) > 40
    end
  end

  describe "render_layered/2 (cor por camada via parser)" do
    # rótulos: bloco de roupa (4) em cima, bloco de cabelo (2) embaixo
    defp blocks_labels do
      rows = Nx.iota({40, 40}, axis: 0)
      cols = Nx.iota({40, 40}, axis: 1)
      band = fn r0, r1 -> Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)) end
      mid_cols = Nx.logical_and(Nx.greater_equal(cols, 8), Nx.less(cols, 32))

      cloth = Nx.logical_and(band.(6, 16), mid_cols)
      hair = Nx.logical_and(band.(24, 34), mid_cols)
      Nx.select(cloth, 4, Nx.select(hair, 2, 0)) |> Nx.as_type(:u8)
    end

    defp chan_max(t, ch), do: t[[.., .., ch]] |> Nx.reduce_max() |> Nx.to_number()

    test "render_layered via parser devolve {h,w,3} (wiring parse→render)" do
      {:ok, layered} = Photo.render_layered(gray_scene(60, 40), [])
      assert Nx.shape(layered) == {60, 40, 3}
    end

    test "render_with_labels com partes que têm borda é não-vazio" do
      out = Photo.render_with_labels(gray_scene(40, 40), blocks_labels(), [])
      assert out |> Nx.sum() |> Nx.to_number() > 0
    end

    test "campo mesclado: roupa fria (teal, verde>vermelho), cabelo quente" do
      layered = Photo.render_with_labels(gray_scene(40, 40), blocks_labels(), [])

      cloth = layered[[6..15, 8..31, ..]]
      hair = layered[[24..33, 8..31, ..]]

      # teal {43,196,178}: verde domina o vermelho
      assert chan_max(cloth, 1) > chan_max(cloth, 0)
      # laranja {255,90,30}: vermelho domina o azul
      assert chan_max(hair, 0) > chan_max(hair, 2)
    end

    test "layer_colors sobrescreve a cor de uma camada (roupa azul)" do
      layered =
        Photo.render_with_labels(gray_scene(40, 40), blocks_labels(),
          layer_colors: %{clothing: {0, 0, 255}}
        )

      cloth = layered[[6..15, 8..31, ..]]
      assert chan_max(cloth, 2) > chan_max(cloth, 0)
    end

    test "preenchimento acende o INTERIOR das partes (que fica escuro sem fill)" do
      labels = blocks_labels()
      sem = Photo.render_with_labels(gray_scene(40, 40), labels, fill: false)

      com =
        Photo.render_with_labels(gray_scene(40, 40), labels,
          fill: true,
          fill_color: 0.6,
          fill_texture: 0.15
        )

      # miolo do bloco de roupa, longe das bordas: só acende com o preenchimento
      miolo = fn out -> out[[9..12, 14..25, ..]] |> Nx.sum() |> Nx.to_number() end
      assert miolo.(com) > miolo.(sem)
    end

    test "bg_opacity acende o fundo com o original atenuado" do
      labels = blocks_labels()
      scene = gray_scene(40, 40)
      canto = fn out -> out[[0..2, 0..2, ..]] |> Nx.sum() |> Nx.to_number() end

      sem = Photo.render_with_labels(scene, labels, bg_opacity: 0.0)
      com = Photo.render_with_labels(scene, labels, bg_opacity: 0.5)

      # o original atenuado aparece atrás -> o fundo (canto) fica mais aceso
      assert canto.(com) > canto.(sem)
    end

    test "transparent_bg devolve RGBA: traço opaco, fundo bem mais transparente" do
      out = Photo.render_with_labels(gray_scene(40, 40), blocks_labels(), transparent_bg: true)
      assert Nx.shape(out) == {40, 40, 4}

      alpha = out[[.., .., 3]]
      # há conteúdo opaco (o traço) e o canto de fundo é bem mais transparente que ele
      assert Nx.to_number(Nx.reduce_max(alpha)) > 200
      assert Nx.to_number(out[0][0][3]) < 200
    end
  end

  test "modo normal (render/2) também respeita o fundo transparente (RGBA)" do
    {:ok, out} = Photo.render(gray_scene(48, 48), preset: "forro-teal", transparent_bg: true)
    assert Nx.shape(out) == {48, 48, 4}
  end

  test "swap_sides inverte as cores do duotone" do
    scene = gray_scene(64, 64)

    {:ok, normal} = Photo.render(scene, preset: "forro-duotone")
    {:ok, swapped} = Photo.render(scene, preset: "forro-duotone", swap_sides: true)

    # sem swap, a metade esquerda pende para o laranja (R = 255); com swap,
    # para o teal (R = 43): o canal R médio da metade esquerda cai
    mean_left_r = fn out ->
      out[[.., 0..31, 0]] |> Nx.as_type(:f32) |> Nx.mean() |> Nx.to_number()
    end

    assert mean_left_r.(normal) > mean_left_r.(swapped)
  end
end
