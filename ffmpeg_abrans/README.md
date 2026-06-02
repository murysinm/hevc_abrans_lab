# ffmpeg_abrans

Форк FFmpeg, в котором модуль энтропийного декодирования CABAC в декодере H.265/HEVC (`libavcodec`) заменён на алгоритм адаптивного двоичного rANS (ABrANS).

## Сборка

Репозиторий содержит скрипты для сборки в двух конфигурациях. Сборка минимальная: включены только компоненты, необходимые для декодирования HEVC.

### Release

```bash
bash build_release.sh
make -j$(nproc)
```

### Debug (без оптимизаций и с отладочными символами)

```bash
bash build_debug.sh
make -j$(nproc)
```

Скрипты вызывают `bear -- make` для генерации `compile_commands.json`; если `bear` не установлен, можно заменить эту строку на `make`.

Исполняемый файл появится в корне репозитория: `./ffmpeg`.

## Использование

Декодирование HEVC-битпотока в rawvideo:

```bash
./ffmpeg -threads 1 -f hevc -i input.265 -c:v rawvideo -f rawvideo output.yuv
```

