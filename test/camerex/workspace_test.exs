defmodule Camerex.WorkspaceTest do
  use Camerex.WorkspaceCase

  alias Camerex.Workspace

  @params %{
    "halo" => 0.6,
    "trail" => 0.7,
    "detail" => 0.5,
    "swap_sides" => false,
    "model" => "u2net"
  }

  @casal Path.expand("exemplos/entrada/casal.jpg")

  defp fake_source!(name, content \\ "fake") do
    path = Path.join(Workspace.tmp_dir(), name)
    File.write!(path, content)
    path
  end

  describe "diretórios" do
    test "root/0 devolve o workspace_root configurado", %{workspace_root: tmp} do
      assert Workspace.root() == tmp
    end

    test "items_dir/0 cria e devolve root/items" do
      dir = Workspace.items_dir()
      assert dir == Path.join(Workspace.root(), "items")
      assert File.dir?(dir)
    end

    test "tmp_dir/0 cria e devolve root/tmp" do
      dir = Workspace.tmp_dir()
      assert dir == Path.join(Workspace.root(), "tmp")
      assert File.dir?(dir)
    end
  end

  describe "slug/1" do
    test "usa o nome sem extensão, minúsculo" do
      assert Workspace.slug("Casal.JPG") == "casal"
    end

    test "remove acentos via decomposição NFD" do
      assert Workspace.slug("Dança no Sertão.jpg") == "danca-no-sertao"
    end

    test "descarta emoji e colapsa espaços em um único hífen" do
      assert Workspace.slug("💃 forró  final 💃.png") == "forro-final"
    end

    test "nome sem nenhum caractere aproveitável vira \"item\"" do
      assert Workspace.slug("💃🕺.mp4") == "item"
    end

    test "trunca em 24 chars sem deixar hífen pendurado" do
      # "abcdefghij-klmnopqrstuv-xyz" cortado em 24 termina em "-",
      # que precisa ser aparado
      assert Workspace.slug("abcdefghij klmnopqrstuv xyz.mp4") ==
               "abcdefghij-klmnopqrstuv"
    end

    test "pontuação vira hífen único" do
      assert Workspace.slug("foto!!do  casal.jpg") == "foto-do-casal"
    end
  end

  describe "generate_id/2" do
    test "segue o formato <ts>-<slug>-<preset>-<rand4>" do
      id = Workspace.generate_id("casal.jpg", "forro-duotone")
      assert id =~ ~r/^\d{8}-\d{6}-casal-forro-duotone-[0-9a-f]{4}$/
    end

    test "timestamp usa o relógio de America/Sao_Paulo" do
      fmt = fn ->
        Calendar.strftime(DateTime.now!("America/Sao_Paulo"), "%Y%m%d-%H%M%S")
      end

      before_ts = fmt.()
      id = Workspace.generate_id("casal.jpg", "ouro")
      after_ts = fmt.()

      # nesse formato, comparação lexicográfica == cronológica
      ts = String.slice(id, 0, 15)
      assert ts >= before_ts and ts <= after_ts
    end

    test "sufixo aleatório distingue ids gerados no mesmo segundo" do
      ids = for _ <- 1..10, do: Workspace.generate_id("casal.jpg", "ouro")
      # probabilidade de 10 rand4 iguais: (1/65536)^9 — nunca flake
      assert ids |> Enum.uniq() |> length() > 1
    end
  end

  describe "create_item/5 + manifest/1 + update_manifest/2" do
    test "copia o original para items/<id>/original.<ext> com extensão minúscula" do
      src = fake_source!("upload.tmp", "bytes-da-foto")

      assert {:ok, id} = Workspace.create_item(src, "Dança.JPG", :photo, "ouro", @params)
      assert id =~ ~r/^\d{8}-\d{6}-danca-ouro-[0-9a-f]{4}$/

      original = Path.join([Workspace.items_dir(), id, "original.jpg"])
      assert File.read!(original) == "bytes-da-foto"
    end

    test "escreve manifest queued com o schema exato do spec §3" do
      src = fake_source!("upload.jpg")
      {:ok, id} = Workspace.create_item(src, "casal.jpg", :photo, "forro-duotone", @params)

      assert {:ok, m} = Workspace.manifest(id)

      # igualdade de mapa completo: prova que TODAS as chaves do schema
      # existem e que nenhuma extra foi inventada
      assert m == %{
               "id" => id,
               "type" => "photo",
               "original_filename" => "casal.jpg",
               "original_file" => "original.jpg",
               "output_file" => "neon.png",
               "preset" => "forro-duotone",
               "params" => @params,
               "status" => "queued",
               "error" => nil,
               "media" => nil,
               "created_at" => m["created_at"],
               "completed_at" => nil,
               "timings_ms" => %{"total" => nil, "per_frame_avg" => nil}
             }

      # created_at é ISO8601 local com offset -03:00 (São Paulo, sem DST)
      assert {:ok, _dt, -10_800} = DateTime.from_iso8601(m["created_at"])
    end

    test "manifest é serializado com Jason pretty" do
      src = fake_source!("upload.jpg")
      {:ok, id} = Workspace.create_item(src, "casal.jpg", :photo, "ouro", @params)

      raw = File.read!(Path.join([Workspace.items_dir(), id, "manifest.json"]))
      assert raw =~ "\n  \"id\""
    end

    test "output_file segue o tipo: photo→neon.png, video→neon.mp4" do
      src = fake_source!("upload.bin")
      {:ok, photo_id} = Workspace.create_item(src, "a.jpg", :photo, "ouro", @params)
      {:ok, video_id} = Workspace.create_item(src, "a.mp4", :video, "ouro", @params)

      assert {:ok, %{"type" => "photo", "output_file" => "neon.png"}} =
               Workspace.manifest(photo_id)

      assert {:ok, %{"type" => "video", "output_file" => "neon.mp4"}} =
               Workspace.manifest(video_id)
    end

    test "origem inexistente devolve erro e não deixa pasta órfã" do
      missing = Path.join(Workspace.tmp_dir(), "nao-existe.jpg")

      assert {:error, :enoent} =
               Workspace.create_item(missing, "x.jpg", :photo, "ouro", @params)

      assert {:ok, []} = File.ls(Workspace.items_dir())
    end

    test "manifest/1 de id desconhecido devolve not_found" do
      assert Workspace.manifest("20990101-000000-x-ouro-ffff") == {:error, :not_found}
    end

    test "update_manifest/2 aplica a função e persiste no disco" do
      src = fake_source!("upload.jpg")
      {:ok, id} = Workspace.create_item(src, "casal.jpg", :photo, "ouro", @params)

      assert {:ok, %{"status" => "processing"}} =
               Workspace.update_manifest(id, &Map.put(&1, "status", "processing"))

      assert {:ok, %{"status" => "processing"}} = Workspace.manifest(id)
    end

    test "update_manifest/2 de id desconhecido devolve not_found" do
      assert Workspace.update_manifest("nope", & &1) == {:error, :not_found}
    end
  end

  describe "list_items/0" do
    test "workspace vazio devolve lista vazia" do
      assert Workspace.list_items() == []
    end

    test "ordena por created_at desc" do
      src = fake_source!("upload.jpg")
      {:ok, a} = Workspace.create_item(src, "a.jpg", :photo, "ouro", @params)
      {:ok, b} = Workspace.create_item(src, "b.jpg", :photo, "ouro", @params)
      {:ok, c} = Workspace.create_item(src, "c.jpg", :photo, "ouro", @params)

      # created_at fixado via update_manifest: os 3 creates caem no mesmo
      # segundo, então a ordem precisa ser controlada pelo teste
      for {id, ts} <- [
            {a, "2026-06-12T10:00:00-03:00"},
            {c, "2026-06-12T12:00:00-03:00"},
            {b, "2026-06-12T11:00:00-03:00"}
          ] do
        {:ok, _} = Workspace.update_manifest(id, &Map.put(&1, "created_at", ts))
      end

      assert Enum.map(Workspace.list_items(), & &1["id"]) == [c, b, a]
    end

    test "ignora pastas sem manifest válido sem quebrar" do
      src = fake_source!("upload.jpg")
      {:ok, id} = Workspace.create_item(src, "ok.jpg", :photo, "ouro", @params)

      File.mkdir_p!(Path.join(Workspace.items_dir(), "pasta-intrusa"))

      corrompido = Path.join(Workspace.items_dir(), "manifest-quebrado")
      File.mkdir_p!(corrompido)
      File.write!(Path.join(corrompido, "manifest.json"), "{nao é json")

      assert Enum.map(Workspace.list_items(), & &1["id"]) == [id]
    end
  end

  describe "delete_item/1, item_path/2, media_url/2" do
    test "delete_item remove a pasta inteira e é idempotente" do
      src = fake_source!("upload.jpg")
      {:ok, id} = Workspace.create_item(src, "x.jpg", :photo, "ouro", @params)

      assert :ok = Workspace.delete_item(id)
      refute File.exists?(Path.join(Workspace.items_dir(), id))
      assert :ok = Workspace.delete_item(id)
    end

    test "delete_item rejeita id que escapa de items/" do
      for invalido <- ["../fora", "a/b", "", ".", ".."] do
        assert_raise ArgumentError, fn -> Workspace.delete_item(invalido) end
      end
    end

    test "item_path/2 monta items/<id>/<file>" do
      assert Workspace.item_path("abc", "neon.png") ==
               Path.join([Workspace.items_dir(), "abc", "neon.png"])
    end

    test "media_url/2 monta a URL servida pelo Plug.Static" do
      assert Workspace.media_url("abc", "thumb.jpg") == "/media/items/abc/thumb.jpg"
    end
  end

  describe "write_thumbs/1" do
    test "gera thumb.jpg do original com lado maior 480 e proporção preservada" do
      {:ok, id} = Workspace.create_item(@casal, "casal.jpg", :photo, "ouro", @params)

      assert :ok = Workspace.write_thumbs(id)

      thumb = Evision.imread(Workspace.item_path(id, "thumb.jpg"))
      {th, tw, 3} = Evision.Mat.shape(thumb)
      assert max(th, tw) == 480

      original = Evision.imread(Workspace.item_path(id, "original.jpg"))
      {oh, ow, 3} = Evision.Mat.shape(original)
      assert_in_delta tw / th, ow / oh, 0.02
    end

    test "gera thumb_neon.jpg quando o resultado existe" do
      {:ok, id} = Workspace.create_item(@casal, "casal.jpg", :photo, "ouro", @params)
      # qualquer imagem serve de resultado: imread detecta o formato pelos
      # bytes, não pela extensão
      File.cp!(@casal, Workspace.item_path(id, "neon.png"))

      assert :ok = Workspace.write_thumbs(id)
      assert %Evision.Mat{} = Evision.imread(Workspace.item_path(id, "thumb_neon.jpg"))
    end

    test "sem resultado ainda, só thumb.jpg é gerado" do
      {:ok, id} = Workspace.create_item(@casal, "casal.jpg", :photo, "ouro", @params)

      assert :ok = Workspace.write_thumbs(id)
      assert File.exists?(Workspace.item_path(id, "thumb.jpg"))
      refute File.exists?(Workspace.item_path(id, "thumb_neon.jpg"))
    end

    test "item de vídeo não gera thumbs nesta fase (frame vem na Fase 4)" do
      src = fake_source!("clip.mp4", "nao é um mp4 de verdade")
      {:ok, id} = Workspace.create_item(src, "clip.mp4", :video, "ouro", @params)

      assert :ok = Workspace.write_thumbs(id)
      refute File.exists?(Workspace.item_path(id, "thumb.jpg"))
      refute File.exists?(Workspace.item_path(id, "thumb_neon.jpg"))
    end
  end

  describe "mark_interrupted_on_boot/0" do
    test "processing vira interrupted; demais status ficam intactos" do
      src = fake_source!("upload.jpg")
      {:ok, presa} = Workspace.create_item(src, "presa.jpg", :photo, "ouro", @params)
      {:ok, pronta} = Workspace.create_item(src, "pronta.jpg", :photo, "ouro", @params)
      {:ok, na_fila} = Workspace.create_item(src, "fila.jpg", :photo, "ouro", @params)

      {:ok, _} = Workspace.update_manifest(presa, &Map.put(&1, "status", "processing"))
      {:ok, _} = Workspace.update_manifest(pronta, &Map.put(&1, "status", "done"))

      assert :ok = Workspace.mark_interrupted_on_boot()

      assert {:ok, %{"status" => "interrupted"}} = Workspace.manifest(presa)
      assert {:ok, %{"status" => "done"}} = Workspace.manifest(pronta)
      assert {:ok, %{"status" => "queued"}} = Workspace.manifest(na_fila)
    end

    test "esvazia tmp/ mas mantém o diretório" do
      File.write!(Path.join(Workspace.tmp_dir(), "upload-abandonado.jpg"), "lixo")

      assert :ok = Workspace.mark_interrupted_on_boot()

      # path montado na mão de propósito: chamar tmp_dir() recriaria o
      # diretório e mascararia uma implementação que esqueceu o mkdir_p
      tmp = Path.join(Workspace.root(), "tmp")
      assert File.dir?(tmp)
      assert {:ok, []} = File.ls(tmp)
    end
  end
end
