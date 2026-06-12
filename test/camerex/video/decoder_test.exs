defmodule Camerex.Video.DecoderTest do
  use ExUnit.Case, async: true

  alias Camerex.Video.Decoder

  setup_all do
    dir = Path.join(System.tmp_dir!(), "camerex-decoder-fixtures")
    File.mkdir_p!(dir)

    mp4 = Path.join(dir, "test.mp4")
    odd = Path.join(dir, "odd.avi")

    unless File.exists?(mp4) do
      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-y -v error -f lavfi -i testsrc=duration=1:size=64x48:rate=8 #{mp4})
        )
    end

    # rawvideo em .avi aceita dimensões ímpares (h264 não aceitaria)
    unless File.exists?(odd) do
      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-y -v error -f lavfi -i testsrc=duration=1:size=62x47:rate=8 -c:v rawvideo #{odd})
        )
    end

    %{mp4: mp4, odd: odd}
  end

  test "decodifica todos os frames do testsrc com escala 640:-2", %{mp4: mp4} do
    frames = mp4 |> Decoder.stream!(%{width: 640, height: 480, fps: 8}) |> Enum.to_list()

    assert length(frames) == 8
    assert Enum.all?(frames, &(Nx.shape(&1) == {480, 640, 3}))
    assert Enum.all?(frames, &(Nx.type(&1) == {:u, 8}))
  end

  test "fps menor que o de origem reduz a contagem de frames", %{mp4: mp4} do
    frames = mp4 |> Decoder.stream!(%{width: 640, height: 480, fps: 4}) |> Enum.to_list()
    assert length(frames) == 4
  end

  test "origem com altura ímpar: altura de saída é par e o fatiamento não dessincroniza",
       %{odd: odd} do
    h = Decoder.target_height(62, 47, 640)
    assert rem(h, 2) == 0

    frames = odd |> Decoder.stream!(%{width: 640, height: h, fps: 8}) |> Enum.to_list()
    assert length(frames) == 8
    assert Nx.shape(hd(frames)) == {h, 640, 3}
  end

  describe "target_height/3" do
    test "espelha o arredondamento do ffmpeg para scale=W:-2" do
      assert Decoder.target_height(64, 48, 640) == 480
      assert Decoder.target_height(62, 47, 640) == 486
      assert Decoder.target_height(1920, 1080, 640) == 360
    end

    test "resultado é sempre par" do
      for w0 <- [61, 64, 99, 640, 1921], h0 <- [47, 48, 360, 1079] do
        assert rem(Decoder.target_height(w0, h0, 640), 2) == 0
      end
    end
  end
end
