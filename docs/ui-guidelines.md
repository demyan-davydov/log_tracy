# Log Tracy — Соглашение по пользовательскому интерфейсу (UI Guidelines)

Документ фиксирует стандарты верстки, типографики, отступов и компонентов интерфейса Log Tracy (Sciter UI).

> [!NOTE]
> Таблицы отображения результатов логов (`.log-table`, `virtual-dlt-view.js`) являются специализированным компонентом и напрямую этим соглашением не регулируются.

---

## 1. Базовые принципы

1. **Тип интерфейса**: Компактный десктопный интерфейс высокой плотности (**Dense Desktop UI**).
2. **Единицы измерения**:
   - `dip` (Device-Independent Pixels) — основной стандарт для всех отступов, размеров компонентов, рамок и скруглений. Обеспечивает корректный рендеринг при любом DPI-масштабировании.
   - `em` / `%` — относительные размеры шрифтов и пропорции колонок.
   - Запрещено использовать `px` для верстки интерфейса (кроме аппаратных исключений).
3. **Цветовая палитра и темы**:
   - Полная поддержка светлой (`theme-light.css`) и тёмной (`theme-dark.css`) тем.
   - Запрещён хардкод цветов (`#...`, `rgb()`, именованные цвета `red`, `blue`). Стилизация строится исключительно на семантических переменных (`var(--bg-*)`, `var(--text-*)`, `var(--border-*)`, `var(--btn-*)`, `var(--log-*)`).

---

## 2. Типографика

- **Шрифты**:
  - Основной UI: `system-ui, -apple-system, Segoe UI, sans-serif`
  - Меню: `font: system; font-rendering-mode: classic;`
  - Код / диапазоны / регулярные выражения: `monospace`

| Уровень / Назначение | Размер | Жирность | Цвет | Селекторы |
| :--- | :--- | :--- | :--- | :--- |
| **Display Title** | `20dip` | `600` | `var(--text-main)` | `.placeholder-title` |
| **Section Title** | `1.25em` (~`15-16dip`) | `600` | `var(--text-main)` | `.section-title` (в диалогах) |
| **Status Title** | `15dip` (compact: `13dip`) | `600` | `var(--text-main)` | `.status-title` |
| **Base Body / Controls** | `1em` | `400` | `var(--text-main)` | `body`, `.row`, `.tab`, кнопки, поля ввода |
| **Secondary / Hints** | `0.9em` / `0.85em` | `400` (Opened: `600`) | `var(--text-label)` | `.hint`, `.filters-empty`, `.recent-file-dir`, `.recent-file-when` |
| **Micro / Badges** | `0.8em` / `10dip` | `700` (бейджи), `400` (флаги) | `var(--text-label)` | `.chip-toggle`, `.recent-file-badge`, `.history-flag` |
| **Error / Alerts** | `0.85em` | `400` | `var(--log-error)` | `.filter-note`, `.recent-file-note`, `.row-error` |

---

## 3. Сетка отступов (Spacing Scale)

| Шаг | Размер | Применение |
| :--- | :--- | :--- |
| **Micro 1** | `1dip` – `2dip` | Границы (`1dip solid`), зазоры каретки (`.gap.caret`), паддинги тулбаров (`padding: 2dip;`), паддинги чипов (`1dip 2dip`) |
| **Micro 2** | `3dip` – `4dip` | Паддинги компактных кнопок (`3dip 6dip`), паддинги чипов правил (`0 3dip`), зазоры чекбоксов |
| **Small** | `5dip` – `6dip` | Паддинг подвала диалогов (`footer: 5dip`), полей ввода (`4dip 6dip`), строк недавних файлов (`6dip 10dip`) |
| **Medium 1** | `8dip` | Шаг между строками формы (`border-spacing: 8dip`), отступ заголовка на пустом экране |
| **Medium 2** | `10dip` – `12dip` | Шаг между секциями (`border-spacing: 12dip`) |
| **Large** | `14dip` – `16dip` | Внутренние вертикальные отступы модальных окон `main` |
| **X-Large** | `18dip` – `20dip` | Внутренние горизонтальные отступы модальных окон `main` |
| **Container**| `24dip` – `28dip` | Центрированный контейнер стартового экрана (`.placeholder-body`) |

---

## 4. Шкала скруглений (Border Radius)

| Уровень | Радиус | Элементы |
| :--- | :--- | :--- |
| **Sharp / Micro** | `2dip` – `3dip` | Поле поиска `.chip-editor`, выпадающий список истории, чипы правил `.filter-chip` |
| **Control** | `4dip` | Текстовые поля `input[type=text]`, заголовки наборов `.filter-set-head`, теги клавиш `<kbd>`, палитра цветов `.swatch` |
| **Card / Tab** | `6dip` – `7dip` | Строки недавних файлов `.recent-file`, табы разделов настроек `.section-tab`, вкладки документа `.tab` (`7dip 7dip 0 0`) |
| **Group Box** | `8dip` | Карточки группировки `.group` (в `rule-editor.htm`) |
| **Circular** | `8dip` (16x16), `13dip` (26x26) | Круглые кнопки действий `.tab-close`, `.filter-button`, `.kept-remove`, кнопка `#btn-add-tab` |

---

## 5. Стандарты компонентов

### 5.1. Вкладки (Tabs Strip)
- Высота полосы табов: `30dip`.
- Вкладка (`.tab`): высота `30dip`, `min-width: 44dip`, `padding: 0 6dip 0 10dip`, скругление `7dip 7dip 0 0`.
- Разделитель (`.tab-sep`): `width: 2dip`, `top: 8dip`, `bottom: 8dip`, фон `var(--tab-separator)`.
- Кнопка закрытия (`.tab-close`): `16x16dip`, `border-radius: 8dip`, скрыта на неактивных вкладках.
- Индикатор загрузки документа (`.tab-progress`): `height: 3dip`, `bottom: 3dip`, скругление `1.5dip`.
- Кнопка добавления (`#btn-add-tab`): `26x26dip`, `border-radius: 13dip`.

### 5.2. Строка поиска и чипы (Chip Search)
- Тулбар: `.search-toolbar`, `padding: 2dip`, плавный переход фона `150ms`.
- Неприменённый ввод: `.search-toolbar.pending { background: var(--bg-search-pending); }`.
- Поле поиска (`.chip-editor`): `min-height: 1.6em`, `padding: 1dip 2dip`, рамка `1dip solid var(--border-input)`, фокус `var(--border-focus)`, скругление `3dip`.
- Чип (`.chip`): `height: 1.3em`, скругление `3dip`, фон из палитры сопоставлений (`--match-color-0..15`).
- Тумблеры чипа (`.chip-toggle`): `font-size: 0.8em`, `padding: 0 2dip`, активный цвет: `var(--chip-toggle-on)`.

### 5.3. Страница фильтров (Filters)
- Тулбар (`.filter-toolbar`): `padding: 4dip`, кнопки «Новый фильтр», «Загрузить фильтр», сообщение команды справа.
- Строка набора (`.filter-set`): `flow: horizontal`; заголовок набора шириной `12em` у всех наборов, чипы правил в остатке строки (`.filter-chips`: `flow: horizontal-wrap`, `border-spacing: 4dip`).
- Заголовок набора (`.filter-set-head`): высота `1.6em`, `padding: 0 4dip`, скругление `4dip`, `font-weight: 600`.
- Чип правила (`.filter-chip`): высота `1.6em`, `padding: 0 3dip`, рамка `1dip solid var(--chip-border)` (ошибка: `var(--log-error)`), скругление `3dip`, не шире остатка строки набора (длинное имя обрезается).
- Чип правила (`.filter-chip`) залит цветом правила, текст на нем черный или белый, что контрастнее (`contrastText` в `resources/rule-colors.js`): в Sciter нет `contrast-color()`. Правило без цвета — фон темы. Вид правила (показать, скрыть, пометить) — значок `.filter-kind` (+, −, ◆: векторная иконка Sciter цвета текста чипа, без рамки) и всплывающая подсказка чипа.
- Кнопки правила (✎, ×): `visibility: visible` при hover чипа, место под них занято всегда.
- Точка на вкладке (`.bottom-tab-dot`): `5dip`, цвет `var(--border-focus)`, появляется через `scale` и `opacity`.

### 5.4. Панели состояний (Status Views)
- Оверлей: `.status-view.overlay` поверх таблицы, перехват фокуса без рамки outline.
- Тело (`.status-body`): ширина `380dip`, отступы `12dip 16dip` (в compact: `6dip 16dip`).
- Прогресс-бар: `height: 6dip`, `margin-top: 10dip` (в compact: `6dip`).

### 5.5. Диалоги (Settings, Rule Editor)
- Контейнер `main`: `overflow-y: auto`, внутренние отступы `16dip 20dip`, шаг между элементами `border-spacing: 12dip`.
- Подвал (`footer`): `background: var(--bg-header)`, `padding: 5dip`, верхняя граница `1dip solid var(--border-color)`.
- Размещение кнопок: кнопка отмены прижата влево через `margin-left: *`, кнопка действия справа (`.primary`).

---

## 6. Реестр выявленных противоречий для будущей нормализации

1. **Единицы `px` вместо `dip`**:
   - `menu-bar.css`: паддинги и отступы заданы в `px` (`2px 8px`, `24px`, `2px`).
   - `search-editor.css:175`: `.chip-search-message { padding: 2px 4px; }`.
   - `settings.htm`, `rule-editor.htm`: границы `1px solid` вместо `1dip solid`.
2. **Отсутствие базового стиля кнопок**:
   - Нет общего стиля тега `button`: кнопки панелей, диалогов и оверлеев статусов используют дефолтный стиль движка.
3. **Фрагментация полей ввода и выпадающих списков**:
   - Отсутствует глобальный стиль для `input[type=text]` в `style.css`.
   - Селекты в `rule-editor.htm` не имеют кастомного оформления рамок и скруглений.
4. **Хардкод цвета ошибки**:
   - `.chip-search-message` использует `color: red;` вместо темы `var(--log-error)`.
5. **Мёртвые стили**:
   - В `style.css` остаются неиспользуемые правила: `menu.window-menu`, `htmlarea.filter-input`, `plaintext.filter-input`.

