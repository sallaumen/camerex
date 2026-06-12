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

  test "models/0 declara u2net e u2netp com urls dos releases da rembg" do
    files = Enum.map(Doctor.models(), & &1.file)
    assert "u2net.onnx" in files
    assert "u2netp.onnx" in files

    assert Enum.all?(
             Doctor.models(),
             &String.starts_with?(&1.url, "https://github.com/danielgatis/rembg/releases/")
           )
  end
end
