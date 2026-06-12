# capture_log: crashes esperados (ex.: testes de DOWN do Jobs) não vazam
# para o stdio — suíte silenciosa e compatível com o relay do ex_check
ExUnit.start(exclude: [:model], capture_log: true)
