defmodule Camerex.Library.ImportTest do
  use Camerex.WorkspaceCase

  alias Camerex.{Library, Workspace}
  alias Camerex.Library.Import

  # árvore sintética no disco: 2 fotos na raiz, 1 vídeo em subpasta,
  # 1 txt ignorado, 1 subpasta com nome acentuado
  defp build_source_tree!(tmp) do
    dir = Path.join(tmp, "origem")
    File.mkdir_p!(Path.join(dir, "Festas Juninas"))

    rgb = Nx.broadcast(Nx.u8(99), {8, 8, 3})
    true = Evision.imwrite(Path.join(dir, "a.png"), Evision.Mat.from_nx_2d(rgb))
    true = Evision.imwrite(Path.join(dir, "b.jpg"), Evision.Mat.from_nx_2d(rgb))

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=1:size=32x24:rate=4) ++
          [Path.join([dir, "Festas Juninas", "clip.mp4"])]
      )

    File.write!(Path.join(dir, "notas.txt"), "não é mídia")
    dir
  end

  describe "scan/1" do
    test "conta mídias recursivamente, ignora não-mídia", %{tmp: tmp} do
      dir = build_source_tree!(tmp)

      assert {:ok, %{media: media, total_bytes: bytes}} = Import.scan(dir)
      assert length(media) == 3
      assert bytes > 0

      rels = media |> Enum.map(& &1.rel_folder) |> Enum.sort()
      assert rels == ["", "", "Festas Juninas"]
    end

    test "diretório inexistente devolve erro legível" do
      assert {:error, msg} = Import.scan("/nao/existe/aqui")
      assert msg =~ "/nao/existe/aqui"
    end

    test "arquivo (não diretório) devolve erro", %{tmp: tmp} do
      file = Path.join(tmp, "x.txt")
      File.write!(file, "oi")
      assert {:error, _} = Import.scan(file)
    end
  end

  describe "run/2" do
    test "importa espelhando subpastas como pastas virtuais sob o destino", %{tmp: tmp} do
      dir = build_source_tree!(tmp)

      assert {:ok, %{imported: 3, skipped: 1, errors: []}} = Import.run(dir, "Eventos")

      raiz = Library.items_in("eventos")
      assert length(raiz) == 2
      assert Enum.all?(raiz, &(&1["status"] == "new"))

      [video] = Library.items_in("eventos/festas-juninas")
      assert video["type"] == "video"
      assert video["original_filename"] == "clip.mp4"

      # arquivo copiado para a biblioteca (autocontida)
      assert File.exists?(Workspace.item_path(video["id"], video["original_file"]))
    end

    test "destino raiz: subpastas do disco viram pastas de primeiro nível", %{tmp: tmp} do
      dir = build_source_tree!(tmp)

      assert {:ok, %{imported: 3}} = Import.run(dir, "")
      assert [_] = Library.items_in("festas-juninas")
    end

    test "erro de scan propaga" do
      assert {:error, _} = Import.run("/nao/existe", "")
    end
  end
end
