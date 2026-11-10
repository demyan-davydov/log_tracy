# Log formats

Формат определяется по началу файла (детекторы в `source/formats/registry.d`). Если ни один формат не подходит, текст открывается как plain text, а бинарные данные не открываются. Каждый формат задает свои колонки таблицы и поля быстрого фильтра.

Файл из списка недавних открывается в том формате, в котором его открывали в прошлый раз (формат и вариант сохраняются в настройках), без повторного определения; формат определяется заново, только если он не сохранен или эта сборка не может его создать (неизвестный формат, неверный вариант). Рядом с файлом в списке показывается значок формата из трех букв, полное имя — в подсказке.

## Supported
- **DLT** (`DLT`, бинарный): протоколы версий 1 и 2 со storage header версий 1 и 2 (файлы DLT), в любом сочетании. В версии 2: ID любой длины, время сообщения (UTC или от старта ECU), кадры сегментированных сообщений показываются текстом (как в dlt-viewer), имя файла, теги и privacy level читаются, но не показываются; payload считается little-endian, как в dlt-viewer. Verbose-аргументы всех типов (с именем и единицей, fixed point, 128-битные целые в hex, float16, целые с кодировкой hex/bin); non-verbose — `[message ID]`, hex и ASCII данных; control-сообщения с именами сервисов и статусов, разбор get_log_info (приложения и контексты с уровнями, trace status и описаниями), get_software_version, connection_info, timezone, marker. ECU берется из стандартного заголовка, если он там есть, иначе из storage header. Запись со слишком большой длиной в стандартном заголовке заканчивается на следующем storage header'е внутри неё и не накрывает следующие записи. Колонки Count, SessionId, MsgId
- **Plain text** (`TXT`): запасной формат, запись = строка
- **Android logcat** (`ADB`): `threadtime` (с годом `-v year` и без), `brief`
- **Kernel log (dmesg)** (`KRN`): обычный вывод (время от загрузки), `<priority>` (`dmesg -r`, `/proc/kmsg`), `dmesg -x` (facility и level по имени), `dmesg -T` (время по часам), `/dev/kmsg` (`priority,seq,usec,flags;message` со строками словаря)
- **Syslog** (`SYS`): BSD / RFC 3164 и journalctl `short`/`short-precise`, ISO (rsyslog, journalctl `short-iso`, с поясом и без), RFC 5424 (MSGID, structured data); `<priority>` дает уровень
- **Web server access log** (`WEB`): Common Log Format и Combined (nginx по умолчанию); HTTP-статус показывается как есть, его класс (5xx/4xx) дает уровень и цвет ячейки
- **CAN trace, candump `-l`** (`CAN`, SocketCAN): CAN, 29-bit ID, Remote, CAN FD, error frames
- **CAN trace, Vector ASC** (`ASC`): шапка (`base hex|dec`, `date`, `timestamps`), CAN, Remote, CAN FD (с символьным именем и без), ErrorFrame, прочие события

## Planned
- **DLT**: декодирование non-verbose сообщений через FIBEX (решение о том, как подключать FIBEX, отложено, см. `docs/fibex.md`); DLT без storage header (по serial и TCP) для потоков; сборка сегментированных сообщений версии 2 из кадров (как плагин сегментации dlt-viewer: строка последнего кадра показывает собранное сообщение), нужен индекс кадров при индексации
- **Логи приложений** «время, уровень, сообщение» (log4j/logback, spdlog, Python logging, glog): встроенные шаблоны, сейчас открываются как plain text
- **Пользовательские форматы**: шаблон из настроек тем же движком, что и встроенные
- **JSON Lines**: колонки по ключам (время, уровень, сообщение по известным ключам)
- **Текстовый экспорт DLT** (dlt-viewer, `dlt-convert -a`)
- **Access log**: построение разбора из строки `log_format` (nginx) / `LogFormat` (Apache); логи ошибок Apache и nginx; W3C Extended (`#Fields:`, IIS)
- **QNX slog2info**
- **Расширения поддержанных форматов**: `dmesg -x -T`, `dmesg --time-format iso`; `candump -x`; даты ASC на других языках; LIN/FlexRay/Ethernet в ASC как отдельные типы
- **CAN**: бинарные BLF и MF4; декодирование сигналов через DBC
- **Кодировки**: UTF-16 с BOM, однобайтные (cp1251, Latin-1); сейчас только UTF-8
- **Потоковые источники**: растущий файл (`tail -f`), затем COM-порт и TCP (запись потока на диск, время прихода для строк без времени)
- **Ручной выбор формата** («Открыть как…»), если определение ошиблось
