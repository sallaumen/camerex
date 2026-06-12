defmodule Camerex.CLITest do
  use ExUnit.Case, async: true

  alias Camerex.CLI

  test "parse_photo/1: posicionais + opções" do
    assert {:ok, %{input: "in.jpg", output: "out.png", opts: opts}} =
             CLI.parse_photo([
               "in.jpg",
               "out.png",
               "--preset",
               "miami",
               "--halo",
               "0.8",
               "--detail",
               "0.2"
             ])

    assert opts[:preset] == "miami"
    assert opts[:halo] == 0.8
    assert opts[:detail] == 0.2
  end

  test "parse_photo/1: sem opções devolve opts vazio (defaults ficam no pipeline)" do
    assert {:ok, %{opts: []}} = CLI.parse_photo(["a.jpg", "b.png"])
  end

  test "parse_photo/1: erro com número errado de posicionais mostra o uso" do
    assert {:error, msg} = CLI.parse_photo(["so_um.jpg"])
    assert msg =~ "uso: mix camerex.foto"
  end

  test "parse_photo/1: preset desconhecido lista os válidos" do
    assert {:error, msg} = CLI.parse_photo(["a", "b", "--preset", "nope"])
    assert msg =~ "forro-duotone"
    assert msg =~ "miami"
  end

  test "parse_photo/1: halo fora de [0,1] é rejeitado" do
    assert {:error, msg} = CLI.parse_photo(["a", "b", "--halo", "1.5"])
    assert msg =~ "halo"
  end

  test "parse_photo/1: opção desconhecida é rejeitada" do
    assert {:error, msg} = CLI.parse_photo(["a", "b", "--nope", "x"])
    assert msg =~ "--nope"
  end

  test "parse_video/1: aceita só --preset" do
    assert {:ok, %{input: "in.mp4", output: "out.mp4", opts: [preset: "pulp"]}} =
             CLI.parse_video(["in.mp4", "out.mp4", "--preset", "pulp"])

    assert {:error, _msg} = CLI.parse_video(["in.mp4", "out.mp4", "--halo", "0.5"])
  end
end
