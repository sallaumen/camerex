defmodule Camerex.DoctorTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Camerex.Doctor

  setup %{tmp_dir: tmp} do
    prev = Application.fetch_env!(:camerex, :models_dir)
    Application.put_env(:camerex, :models_dir, tmp)
    on_exit(fn -> Application.put_env(:camerex, :models_dir, prev) end)
    %{dir: tmp}
  end

  defp spec_for(content, file) do
    %{
      id: "fake",
      file: file,
      md5: :crypto.hash(:md5, content) |> Base.encode16(case: :lower),
      url: "http://example.invalid/#{file}"
    }
  end

  test "md5_file/1 calcula o md5 em streaming", %{dir: dir} do
    path = Path.join(dir, "x.bin")
    File.write!(path, "camerex")

    assert Doctor.md5_file(path) ==
             :crypto.hash(:md5, "camerex") |> Base.encode16(case: :lower)
  end

  test "model_status/2: :ok quando o arquivo existe com md5 correto", %{dir: dir} do
    File.write!(Path.join(dir, "fake.onnx"), "abc")
    assert Doctor.model_status(spec_for("abc", "fake.onnx"), dir) == :ok
  end

  test "model_status/2: :missing sem arquivo", %{dir: dir} do
    assert Doctor.model_status(spec_for("abc", "nada.onnx"), dir) == :missing
  end

  test "model_status/2: :bad_md5 com conteúdo divergente", %{dir: dir} do
    File.write!(Path.join(dir, "fake.onnx"), "outra coisa")
    assert Doctor.model_status(spec_for("abc", "fake.onnx"), dir) == :bad_md5
  end

  test "check/1: models :ok quando todos os modelos batem", %{dir: dir} do
    File.write!(Path.join(dir, "fake.onnx"), "abc")
    assert %{models: :ok} = Doctor.check([spec_for("abc", "fake.onnx")])
  end

  test "check/1: models {:error, msg} cita o arquivo problemático" do
    assert %{models: {:error, msg}} = Doctor.check([spec_for("abc", "faltando.onnx")])
    assert msg =~ "faltando.onnx"
  end

  test "check/0: ffmpeg :ok quando está no PATH (pré-requisito da máquina de dev)" do
    assert %{ffmpeg: :ok} = Doctor.check()
  end

  test "check/1: ffmpeg {:error, msg} quando o PATH não o contém" do
    prev = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")

    try do
      assert %{ffmpeg: {:error, msg}} = Doctor.check([])
      assert msg =~ "ffmpeg"
    after
      System.put_env("PATH", prev)
    end
  end

  test "problems/1: lista vazia quando ffmpeg e modelos estão ok" do
    assert Doctor.problems(%{ffmpeg: :ok, models: :ok}) == []
  end

  test "problems/1: traduz cada erro em mensagem + comando de correção" do
    problems =
      Doctor.problems(%{ffmpeg: {:error, "sem ffmpeg"}, models: {:error, "modelos faltando"}})

    assert %{msg: "sem ffmpeg", cmd: "brew install ffmpeg"} in problems
    assert %{msg: "modelos faltando", cmd: "mix camerex.setup"} in problems
  end

  test "models/0 declara os de segmentação (rembg) e o parser (HuggingFace)" do
    by_file = Map.new(Doctor.models(), &{&1.file, &1})

    assert Map.has_key?(by_file, "u2net.onnx")
    assert Map.has_key?(by_file, "u2netp.onnx")
    assert Map.has_key?(by_file, "segformer_b2_clothes.onnx")

    # u2net/u2netp vêm dos releases da rembg
    for f <- ~w(u2net.onnx u2netp.onnx) do
      assert String.starts_with?(by_file[f].url, "https://github.com/danielgatis/rembg/releases/")
    end

    # o parser de human parsing vem do HuggingFace
    assert String.starts_with?(
             by_file["segformer_b2_clothes.onnx"].url,
             "https://huggingface.co/"
           )
  end
end
