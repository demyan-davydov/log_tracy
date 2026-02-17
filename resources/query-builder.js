// query-builder.js

export class QueryBuilder extends Element {

    constructor(props) {
        super(props);
        // Модель данных: ДЕРЕВО
        // Root - это всегда группа
        this.model = {
            type: 'group',
            id: 'root',
            children: []
        };

        this.selectionIds = new Set(); // Хранит ID выделенных элементов
        this.inputBuffer = "";      // Текущий текст ввода

        //this.styleset = props.styleset || (__DIR__ + "query-builder.css#query-builder");
    }

    componentDidMount() {
        this.render();
    }

    ["on mousedown"](evt) {
        console.log("query-builder.js: Mouse down on2 " + evt.target);
        // Если кликнули не по токену и не по оператору
        if (evt.target === this || evt.target.classList.contains('group')) {
            // Предотвращаем стандартное выделение текста
            evt.preventDefault();
            // Переносим фокус в конец
            if (this.inputEl) {
                this.inputEl.focus();
            }
        }
    }

    // --- RENDER ENGINE ---

    render() {
        this.innerHTML = "";

        // Рекурсивный рендер дерева
        this.renderGroup(this.model, this);

        // Инпут всегда в конце корневого уровня (для упрощения UX)
        // В более сложной версии инпут должен "прыгать" внутрь активной группы
        this.createInput(this);
    }

    renderGroup(groupData, container) {
        // Если это не корень, создаем обертку
        let targetContainer = container;

        if (groupData.id !== 'root') {
            const groupEl = document.createElement('div');
            groupEl.className = 'group explicit';
            if (this.selectionIds.has(groupData.id)) groupEl.classList.add('selected');

            // Клик по группе выделяет её
            groupEl.onmousedown = (evt) => {
                evt.stopPropagation();
                this.toggleSelectionIds(groupData.id, evt.shiftKey);
            };

            container.append(groupEl);
            targetContainer = groupEl;
        }

        // Рендерим детей
        for (const child of groupData.children) {
            if (child.type === 'token') {
                this.renderToken(child, targetContainer);
            } else if (child.type === 'operator') {
                const op = document.createElement('span');
                op.className = 'operator';
                op.innerText = child.value;
                targetContainer.append(op);
            } else if (child.type === 'group') {
                this.renderGroup(child, targetContainer);
            }
        }
    }

    renderToken(tokenData, container) {
        const el = document.createElement('span');
        el.className = `token ${tokenData.isRegex ? 'regex' : ''}`;
        el.innerText = tokenData.value;
        if (this.selectionIds.has(tokenData.id)) el.classList.add('selected');

        el.onmousedown = (evt) => {
            evt.stopPropagation(); // Чтобы не кликнуть по контейнеру
            this.toggleSelectionIds(tokenData.id, evt.shiftKey); // Shift+Click Logic
        };

        container.append(el);
    }

    createInput(container) {
        console.log("query-builder.js: createInput");
        const input = document.createElement('input');
        input.className = 'ghost';
        input.type = 'text';
        input.value = this.inputBuffer;

        // ВАЖНО: Добавляем подсказку, чтобы поле было видно
        input.attributes["placeholder"] = "Type query (e.g. Error & 500)...";

        //input.onkeydown = (evt) => this.handleKeyDown(evt);
        input.addEventListener('keydown', this.handleKeyDown.bind(this));
        input.oninput = (evt) => { this.inputBuffer = input.value; };

        container.append(input);

        // Сохраняем ссылку на инпут, чтобы фокусироваться на нем
        this.inputEl = input;

        // Авто-фокус (с небольшой задержкой для надежности рендера)
        input.timer(20, () => {
            if (document.activeElement !== input) input.focus();
        });
    }

    // --- LOGIC & CONTROLLER ---

    handleKeyDown(evt) {
        const key = evt.key;
        const val = this.inputBuffer;
        const code = evt.code;
        var charCode = evt.which || evt.keyCode;

        // Лог для отладки: посмотрим, что реально приходит
        console.log(`Event: code=${code}, key=${key}, val=${val}, keyCode=${evt.keyCode}, shiftKey=${evt.shiftKey}, charCode=${charCode}`);

        // 1. Enter: Создать токен
        if (key === 'Enter') {
            if (val.trim()) {
                this.addToken(val);
                this.inputBuffer = "";
                this.render();
            }
            return true;
        }

        // 2. Спецсимволы (&, |)
        if (key === '&' || key === '|') {
            console.log("query-builder.js: handleKeyDown == & or |: " + key);
            // Если есть текст в буфере, сначала добавим его как токен
            if (val.trim()) {
                this.addToken(val);
                this.inputBuffer = "";
            }

            // ВАЛИДАЦИЯ: Можно ли добавить оператор?
            if (this.canAddOperator()) {
                this.addOperator(key === '&' ? 'AND' : 'OR');
                this.render();
            } else {
                this.showErrorTooltip(evt.target, "Enter search criteria first");
            }

            return true; // Prevent default input
        }

        // 3. Группировка (Символ '(' )
        if (key === '(') {
            console.log("query-builder.js: handleKeyDown == (: " + key);
            if (this.selectionIds.size > 0) {
                this.groupSelectedItems();
                this.render();
                return true;
            }
        }

        // 4. Backspace
        if (key === 'Backspace' && val === "") {
            // Удаляем последний элемент или выделенные
            this.removeLastOrSelected();
            this.render();
            return true;
        }

        return false;
    }

    // --- CORE LOGIC METHODS ---

    // Проверка валидности оператора (левый операнд)
    canAddOperator() {
        const children = this.model.children;
        if (children.length === 0) return false;

        const lastItem = children[children.length - 1];
        // Нельзя ставить оператор после другого оператора
        if (lastItem.type === 'operator') return false;

        return true;
    }

    addToken(text) {
        const isRegex = text.includes('*') || text.includes('?');
        this.model.children.push({
            type: 'token',
            id: Window.this.uuid(), // Sciter native UUID gen
            value: text,
            isRegex: isRegex
        });
    }

    addOperator(opType) {
        this.model.children.push({
            type: 'operator',
            id: Window.this.uuid(),
            value: opType
        });
    }

    // API Выделения
    toggleSelectionIds(id, append) {
        if (!append) this.selectionIds.clear();

        if (this.selectionIds.has(id)) this.selectionIds.delete(id);
        else this.selectionIds.add(id);

        this.render();
    }

    // Логика группировки выделенного
    groupSelectedItems() {
        // Упрощенная логика: работаем только с корневым уровнем для примера
        // В полной версии нужно найти общего родителя

        const children = this.model.children;
        const selectedIndices = [];

        // Находим индексы выделенных элементов
        children.forEach((child, index) => {
            if (this.selectionIds.has(child.id)) selectedIndices.push(index);
        });

        if (selectedIndices.length < 1) return;

        // Сортируем и проверяем целостность (должны идти подряд? необязательно, но желательно)
        selectedIndices.sort();
        const firstIdx = selectedIndices[0];
        const lastIdx = selectedIndices[selectedIndices.length - 1];

        // Извлекаем элементы
        // Важно: slice берет копию, splice изменяет оригинал
        const elementsToGroup = children.slice(firstIdx, lastIdx + 1);

        // Создаем новую группу
        const newGroup = {
            type: 'group',
            id: Window.this.uuid(),
            children: elementsToGroup
        };

        // Заменяем кусок массива на новую группу
        this.model.children.splice(firstIdx, (lastIdx - firstIdx + 1), newGroup);

        // Сброс выделения
        this.selectionIds.clear();
    }

    removeLastOrSelected() {
        if (this.selectionIds.size > 0) {
            // Удаление по ID (фильтрация)
            this.model.children = this.model.children.filter(item => !this.selectionIds.has(item.id));
            this.selectionIds.clear();
        } else {
            // Просто удаляем последний
            this.model.children.pop();
        }
    }

    showErrorTooltip(anchor, text) {
        // Sciter JS API для попапов
        const popup = document.createElement('popup');
        popup.className = 'error-toast';
        popup.innerText = text;
        document.body.append(popup);

        // Показываем относительно инпута
        anchor.popup(popup, {
            anchorAt: 2, // bottom-center
            popupAt: 8   // top-center
        });

        // Авто-скрытие
        setTimeout(() => popup.remove(), 2000);
    }

    // ==========================================
    // СЕКЦИЯ 1: SERIALIZATION (JSON)
    // ==========================================

    saveCurrentToJson() {
        // Мы не сохраняем технические ID (uuid), они пересоздадутся при загрузке,
        // но сохраняем структуру, значения и флаги.
        const serializeNode = (node) => {
            const cleanNode = { type: node.type };

            if (node.type === 'token') {
                cleanNode.value = node.value;
                cleanNode.isRegex = node.isRegex;
                cleanNode.caseSensitive = node.caseSensitive || false;
            } else if (node.type === 'operator') {
                cleanNode.value = node.value;
            } else if (node.type === 'group') {
                cleanNode.children = node.children.map(serializeNode);
            }
            return cleanNode;
        };

        // Сериализуем всё дерево (начиная с корня)
        return JSON.stringify(serializeNode(this.model));
    }

    loadCurrentFromJson(jsonString) {
        try {
            const rawData = JSON.parse(jsonString);

            // Рекурсивное восстановление с генерацией новых UUID для UI
            const hydrateNode = (node) => {
                // Восстанавливаем ID для внутренней работы UI
                node.id = Window.this.uuid(); // Sciter UUID

                if (node.type === 'group' && node.children) {
                    node.children = node.children.map(hydrateNode);
                }
                return node;
            };

            this.model = hydrateNode(rawData);
            this.inputBuffer = "";
            this.selectionIds.clear();
            this.render(); // Полная перерисовка
            return true;
        } catch (e) {
            console.error("Failed to load JSON", e);
            this.showErrorTooltip(this, "Invalid JSON format");
            return false;
        }
    }

    // ==========================================
    // СЕКЦИЯ 2: REGEX GENERATION
    // ==========================================

    getCurrentRegex() {
        return this.buildRegexFromNode(this.model);
    }

    buildRegexFromNode(node) {
        if (node.type === 'token') {
            if (node.isRegex) {
                // Если это пользовательский regex, вставляем как есть.
                // Можно обернуть в (?:), чтобы флаги не вытекли.
                return `(?:${node.value})`;
            } else {
                // Экранируем спецсимволы, если это просто текст
                const escaped = node.value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                return escaped;
            }
        }

        if (node.type === 'group') {
            // Пустая группа ничего не ищет
            if (!node.children || node.children.length === 0) return "";

            let pattern = "(?:"; // Non-capturing group для всей структуры

            for (let i = 0; i < node.children.length; i++) {
                const child = node.children[i];

                if (child.type === 'operator') {
                    if (child.value === 'OR') {
                        pattern += "|";
                    } else if (child.value === 'AND') {
                        // Важное решение: AND в регулярке -> это последовательность ".*"
                        // Это означает "Слева, затем где-то справа".
                        // Если нужно искать на одной строке, используем .*?
                        pattern += ".*?";
                    }
                } else {
                    pattern += this.buildRegexFromNode(child);
                }
            }
            pattern += ")";
            return pattern;
        }

        return "";
    }

    // ==========================================
    // СЕКЦИЯ 3: MRU (Most Recently Used)
    // ==========================================

    // Инициализация MRU (вызвать в constructor)
    initMRU(limit = 10) {
        this.mruLimit = limit;
        this.mruList = [];
        // В реальном приложении здесь будет загрузка из файла настроек Sciter
        // this.mruList = Settings.load('searchHistory') || [];
    }

    saveCurrentToMRU() {
        const json = this.saveCurrentToJson();

        // 1. Проверяем, не пустой ли запрос (пустую группу {} лучше не сохранять)
        const parsed = JSON.parse(json);
        if (!parsed.children || parsed.children.length === 0) return;

        // 2. Удаляем дубликат, если такой запрос уже был (чтобы поднять его наверх)
        const existingIndex = this.mruList.indexOf(json);
        if (existingIndex !== -1) {
            this.mruList.splice(existingIndex, 1);
        }

        // 3. Добавляем в начало
        this.mruList.unshift(json);

        // 4. Обрезаем лишнее
        if (this.mruList.length > this.mruLimit) {
            this.mruList = this.mruList.slice(0, this.mruLimit);
        }

        // 5. Сохраняем (здесь заглушка, в Sciter нужен вызов host метода или запись в файл)
        console.log("MRU Updated:", this.mruList);
    }

    getMRUList() {
        // Возвращаем копию списка
        return [...this.mruList];
    }
}