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
end
