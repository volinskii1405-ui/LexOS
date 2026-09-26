#!/usr/bin/env python3
"""mklang.py - LexOS's translations: disk/SYSTEM/LANG.DAT from the table below.

    python3 tools/mklang.py

LexOS's own text is English; with the system's language set to Russian
or Spanish (the first boot's last step - USER.CFG), what's printed and
drawn goes through tr_lookup (src/langui.asm): an English string found
in LANG.DAT - by its FNV-1a hash - gives its Russian or Spanish version
instead. The file lives on LexOS's own disk (/SYSTEM/LANG.DAT, put there
by tools/mkdisk.py), loaded at boot: the kernel itself has no room left.

A translation is keyed by the English string's label in src/*.asm (its
text is read from there). The text here is UTF-8; it's written out in
LexOS's code page - code page 866 for Russian (the letters src/lang.asm
puts into the font), and for Spanish the accented letters in the places
src/lang.asm gives them (lang_es_codes: code page 866 has none).

LANG.DAT: "LXTR", the count, then that many (hash, Russian, Spanish) -
dwords, the strings' offsets in the file - sorted by the hash, then the
strings, each ending with 0.

Help lines ("help_lNN") give only their description: the command part
(everything before " - ") is taken from src/data.asm, so it lines up."""
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# Spanish letters -> where src/lang.asm puts them (lang_es_codes)
ES = {'á': 0xF2, 'é': 0xF3, 'í': 0xF4, 'ó': 0xF5, 'ú': 0xF6, 'ñ': 0xF7,
      'Ñ': 0xFC, 'ü': 0xFD, '¿': 0xB5, '¡': 0xB6, 'ç': 0xB7, 'Ç': 0xB8,
      'Á': ord('A'), 'É': ord('E'), 'Í': ord('I'), 'Ó': ord('O'), 'Ú': ord('U')}
SAME = {'«': '"', '»': '"', '—': '-', '–': '-', '…': '...', '’': "'", '‘': "'"}


def encode(text, lang):
    out = []
    for ch in text.replace('\\n', '\n'):
        ch = SAME.get(ch, ch)
        for c in ch:
            if c == '\n':
                out += [13, 10]
            elif ord(c) < 128:
                out.append(ord(c))
            elif lang == 'es' and c in ES:
                out.append(ES[c])
            elif lang == 'ru':
                out.append(c.encode('cp866')[0])
            else:
                sys.exit('mklang: %r can\'t be written in %s' % (c, lang))
    return out


# label: (Russian, Spanish)
TR = {
# ---- the shell ----
'msg_unknown': ('Нет такой команды: ', 'Comando desconocido: '),
'msg_shutdown': ('Выключение...\\n', 'Apagando...\\n'),
'msg_color_ok': ('Цвет изменён.\\n', 'Color cambiado.\\n'),
'msg_help_title': ('Справка LexOS - страница ', 'Ayuda de LexOS - página '),
'msg_help_footer': ('\\n[A] Назад   [D] Дальше   [ESC] В консоль\\n', '\\n[A] Atrás   [D] Siguiente   [ESC] Volver a la consola\\n'),
'msg_history_empty': ('История команд пока пуста.\\n', 'Aún no hay historial de comandos.\\n'),
'msg_fs_full': ('Нет свободных мест для файлов.\\n', 'No quedan huecos libres para archivos.\\n'),
'msg_fs_notfound': ('Не найдено.\\n', 'No encontrado.\\n'),
'msg_cd_no_prev': ('Вернуться пока некуда.\\n', 'Aún no hay carpeta a la que volver.\\n'),
'msg_bang_none': ('До этой команды ничего не было.\\n', 'No hay ningún comando anterior.\\n'),
'msg_fs_removed': ('Удалено.\\n', 'Eliminado.\\n'),
'msg_rm_removed_suffix': (' удалено.\\n', ' eliminados.\\n'),
'msg_fs_empty': ('Пусто.\\n', 'Vacío.\\n'),
'msg_fs_write_error': ('Ошибка записи на диск.\\n', 'Error al escribir en el disco.\\n'),
'msg_fs_usage_ren': ('Использование: ren <имя> <новое_имя>\\n', 'Uso: ren <nombre> <nombre_nuevo>\\n'),
'msg_fs_name_taken': ('Здесь такое уже есть.\\n', 'Ya existe aquí.\\n'),
'msg_fs_renamed': ('Переименовано.\\n', 'Renombrado.\\n'),
'msg_fs_disk_full': ('Место на диске кончилось - сохранено, что влезло.\\n', 'No queda espacio - se guardó lo que cabía.\\n'),
'msg_uranium_usage': ('Использование: uranium <имя>\\n', 'Uso: uranium <nombre>\\n'),
'msg_uranium_not_text': ('Это программа. Редактируйте её через hex.\\n', 'Es un programa. Edítalo con hex.\\n'),
'msg_uranium_header1': ('Редактор LexOS - ', 'Editor de LexOS - '),
'msg_uranium_header3': (' байт)\\n\\n', ' bytes)\\n\\n'),
'msg_uranium_header3m': (' байт, не сохранено)\\n\\n', ' bytes, sin guardar)\\n\\n'),
'msg_uranium_footer': ('Ctrl+B=Сохр.и выйти Ctrl+H=Сохр. Ctrl+F=Поиск ESC=Выход', 'Ctrl+B=Guardar y salir Ctrl+H=Guardar Ctrl+F=Buscar ESC'),
'msg_uranium_ln': ('Стр ', 'Lín '),
'msg_uranium_col': (', Кол ', ', Col '),
'msg_uranium_saved_flash': ('Сохранено.', 'Guardado.'),
'msg_uranium_notfound_flash': ('Не найдено.', 'No encontrado.'),
'msg_uranium_search_prompt': ('Найти: ', 'Buscar: '),
'msg_uranium_confirm': ('Сохранить и выйти?\\n\\nY / Enter - ДА.         N / Esc - НЕТ, вернуться к тексту.',
                        '¿Guardar y salir?\\n\\nY / Enter - SÍ.         N / Esc - NO, volver al texto.'),
'msg_uranium_unsaved': ('Есть несохранённые изменения.\\n\\nY / Enter - выйти БЕЗ сохранения.\\nS         - сохранить и выйти.\\nN / Esc   - вернуться к тексту.',
                        'Hay cambios sin guardar.\\n\\nY / Enter - salir SIN guardarlos.\\nS         - guardarlos y salir.\\nN / Esc   - volver al texto.'),
'msg_bytes_suffix': (' байт\\n', ' bytes\\n'),
'msg_fs_usage_mkdir': ('Использование: mkdir <имя>\\n', 'Uso: mkdir <nombre>\\n'),
'msg_fs_dir_created': ('Папка создана.\\n', 'Carpeta creada.\\n'),
'msg_fs_is_dir': ('Это папка, а не файл.\\n', 'Es una carpeta, no un archivo.\\n'),
'msg_fs_not_a_dir': ('Это не папка.\\n', 'No es una carpeta.\\n'),
'msg_fs_usage_cp': ('Использование: cp <имя> <новое_имя>\\n', 'Uso: cp <nombre> <nombre_nuevo>\\n'),
'msg_fs_copied': ('Скопировано.\\n', 'Copiado.\\n'),
'msg_cp_copied_suffix': (' скопировано.\\n', ' copiados.\\n'),
'msg_fs_usage_mv': ('Использование: mv <имя> <путь>\\n', 'Uso: mv <nombre> <ruta>\\n'),
'msg_fs_moved': ('Перемещено.\\n', 'Movido.\\n'),
'msg_mv_moved_suffix': (' перемещено.\\n', ' movidos.\\n'),
'msg_fs_path_notfound': ('Путь не найден.\\n', 'Ruta no encontrada.\\n'),
'msg_run_usage': ('Использование: run <имя>\\n', 'Uso: run <nombre>\\n'),
'msg_run_notprogram': ('Это не программа. Создать её можно в hex.\\n', 'No es un programa. Créalo con hex.\\n'),
'msg_bld_usage': ('Использование: bld <имя>  (создаёт пустой файл)\\n', 'Uso: bld <nombre>  (crea un archivo vacío)\\n'),
'msg_bld_done': ('Файл создан.\\n', 'Archivo creado.\\n'),
'msg_clock_on': ('Часы включены (ещё раз clock - выключить).\\n', 'Reloj activado (clock otra vez lo apaga).\\n'),
'msg_clock_off': ('Часы выключены.\\n', 'Reloj desactivado.\\n'),
'msg_task_killed': ('Остановлено.\\n', 'Detenido.\\n'),
'msg_console_first': ('Это первая консоль - она остаётся. (Alt+T - ещё одна, Alt+1..9 - переключение.)\\n',
                      'Es la primera consola - se queda. (Alt+T abre otra, Alt+1..9 cambia.)\\n'),
'msg_user_cfg_protected': ('USER.CFG защищён - его нельзя удалить, переименовать, переместить или изменить.\\n',
                           'USER.CFG está protegido - no se puede borrar, renombrar, mover ni editar.\\n'),
# ---- help ----
'help_l01': ('показать этот список', 'mostrar esta lista'),
'help_l02': ('очистить экран', 'limpiar la pantalla'),
'help_l03': ('вывести текст', 'mostrar un texto'),
'help_l04': ('цвет текста (например color 0f, color 09)', 'color del texto (p. ej. color 0f, color 09)'),
'help_l05': ('первые 8 байт первых 8 секторов диска', 'primeros 8 bytes de los 8 primeros sectores'),
'help_l06': ('файлы и папки здесь', 'archivos y carpetas de aquí'),
'help_l08': ('показать содержимое файла n', 'mostrar el contenido del archivo n'),
'help_l10': ('удалить файл или папку n', 'borrar el archivo o la carpeta n'),
'help_l11': ('переименовать файл или папку n в new', 'renombrar el archivo o carpeta n a new'),
'help_l12': ('размер содержимого файла n', 'tamaño del contenido del archivo n'),
'help_l14': ('создать папку n', 'crear la carpeta n'),
'help_l61': ('создать пустой файл n', 'crear un archivo vacío n'),
'help_l15': ('войти в папку n', 'entrar en la carpeta n'),
'help_l16': ('на папку выше', 'ir a la carpeta de arriba'),
'help_l17': ('в папку по пути (cd, cd /, cd // - корень)', 'ir a una carpeta por ruta (cd, cd /, cd // = raíz)'),
'help_l71': ('в прошлую папку / повторить последнюю команду', 'a la carpeta anterior / repetir el último comando'),
'help_l18': ('переместить файл n в папку (или *.ext - много)', 'mover el archivo n a una carpeta (o *.ext)'),
'help_l19': ('копировать файл n в new (*.ext - в папку <new>)', 'copiar el archivo n a new (*.ext: a la carpeta <new>)'),
'help_l20': ('путь текущей папки', 'ruta de la carpeta actual'),
'help_l21': ('все файлы и папки деревом', 'todos los archivos y carpetas en árbol'),
'help_l22': ('перезагрузить систему', 'reiniciar el sistema'),
'help_l23': ('о системе', 'información del sistema'),
'help_l24': ('устройства и их состояние', 'dispositivos y su estado'),
'help_l25': ('hex/asm-редактор, без точки в имени добавит .BIN', 'editor hex/asm, añade .BIN si el nombre no tiene punto'),
'help_l26': ('запустить программу', 'ejecutar un programa'),
'help_l27': ('прочитать сектор диска драйвером ATA', 'leer un sector del disco con el driver ATA'),
'help_l28': ('выключить систему', 'apagar el sistema'),
'help_l29': ('  (Вверх/Вниз - история команд)\\n', '  (Arriba/Abajo = historial de comandos)\\n'),
'help_l30': ('  Имена: хранятся ЗАГЛАВНЫМИ, поиск без учёта регистра,\\n', '  Nombres: se guardan en MAYÚSCULAS, la búsqueda ignora mayúsculas,\\n'),
'help_l31': ('         расширение пишите сами (например uranium notes.txt)\\n', '         escribe tú la extensión (p. ej. uranium notes.txt)\\n'),
'help_l32': ('текущая дата', 'fecha actual'),
'help_l33': ('текущее время', 'hora actual'),
'help_l34': ('короткий звук (частота в hex)', 'un pitido corto (frecuencia en hex)'),
'help_l35': ('отправить текст в COM1', 'enviar texto por COM1'),
'help_l38': ('скрипт: set, input, if/while/for, goto (README)', 'un script: set, input, if/while/for, goto (README)'),
'help_l39': ('найти текст t в файле n и подсветить', 'buscar el texto t en el archivo n y resaltarlo'),
'help_l40': ('первые k строк файла n (по умолчанию 10)', 'las primeras k líneas del archivo n (10 si no)'),
'help_l41': ('последние k строк файла n (по умолчанию 10)', 'las últimas k líneas del archivo n (10 si no)'),
'help_l42': ('открыть файл n в полноэкранном редакторе', 'abrir el archivo n en el editor de pantalla completa'),
'help_l43': ('список выполненных команд', 'lista de los comandos ejecutados'),
'help_l44': ('занятость мест папок / доп. секторов', 'uso de huecos de carpetas / sectores extra'),
'help_l45': ('запустить маленькую .com-программу MS-DOS', 'ejecutar un pequeño programa .com de MS-DOS'),
'help_l62': ('защищённая программа (файлы, графика: apps/)', 'un programa protegido (archivos, gráficos: apps/)'),
'help_l46': ('принять файл через COM1', 'recibir un archivo por COM1'),
'help_l47': ('рисовалка мышью, сохраняет в n.BMP', 'dibujar con el ratón, guarda en n.BMP'),
'help_l48': ('показать картинку из paint (.BMP)', 'mostrar un dibujo de paint (.BMP)'),
'help_l49': ('музыка AdLib или звук WAV', 'música AdLib o sonido WAV'),
'help_l50': ('ROM CHIP-8 (клавиши 1234/qwer/asdf/zxcv)', 'una ROM CHIP-8 (teclas 1234/qwer/asdf/zxcv)'),
'help_l51': ('скрипт черепашьей графики (FORWARD/LEFT/...)', 'un script de tortuga (FORWARD/LEFT/...)'),
'help_l52': ('файлы в общей папке хоста', 'archivos de la carpeta compartida del host'),
'help_l53': ('взять файл из общей папки хоста', 'copiar un archivo desde la carpeta del host'),
'help_l55': ('положить файл n в общую папку хоста', 'copiar el archivo n a la carpeta del host'),
'help_l56': ('сетевая карта и адрес (или задать адрес)', 'la tarjeta de red y su dirección (o fijarla)'),
'help_l57': ('n эхо-запросов ICMP; nslookup <имя>; dhcp', 'n pings ICMP (4 si no); nslookup <nombre>; dhcp'),
'help_l64': ('скачать http://host[:port]/path в файл', 'descargar http://host[:port]/ruta a un archivo'),
'help_l66': ('раздать этот диск в веб (make run: :8080)', 'servir este disco en la web (make run: :8080)'),
'help_l67': ('чат с другими LexOS в сети (make lan1/lan2)', 'chat con otras LexOS de la red (make lan1/lan2)'),
'help_l68': ('окна, мышь, панель задач; ещё раз - выйти', 'ventanas, ratón, barra de tareas; otra vez: salir'),
'help_l69': ('что играет, и громкость', 'qué suena, y el volumen'),
'help_l63': ('время с сервера точного времени', 'poner la hora desde un servidor de tiempo'),
'help_l58': ('задачи / остановить; <cmd> & - play в фоне', 'tareas / detener una; <cmd> & - play de fondo'),
'help_l59': ('часы в правом верхнем углу (фоновая задача)', 'un reloj arriba a la derecha (tarea de fondo)'),
'help_l70': ('система кратко (с котом Lex) / время работы', 'el sistema de un vistazo (con Lex) / tiempo encendido'),
'help_l72': ('кот Lex что-нибудь скажет (или ваш текст)', 'el gato Lex dice algo (o lo que escribas)'),
'help_l73': ('вывод a в команду b (grep, head...) / в файл f', 'la salida de a a b (grep, head...) / al archivo f'),
'help_l76': ('веб-браузер / компилятор C', 'navegador web / compilador de C'),
'help_l74': ('с датой и размером / только чтение или нет', 'con fecha y tamaño / solo lectura o no'),
'help_l75': ('проверить файловую систему (и исправить ошибки)', 'revisar el sistema de archivos (y arreglarlo)'),
'jnl_m_ro': ('Файл только для чтения (attrib -r <имя> разрешит изменения).\n', 'Es de solo lectura (attrib -r <nombre> permite cambiarlo).\n'),
'jnl_m_attr_ro': (': только чтение\n', ': solo lectura\n'),
'jnl_m_attr_rw': (': можно изменять\n', ': se puede cambiar\n'),
'jnl_m_attr_use': ('Использование: attrib <имя> [+r | -r]\n', 'Uso: attrib <nombre> [+r | -r]\n'),
'jnl_m_fsck_head': ('Проверка файловой системы...\n', 'Revisando el sistema de archivos...\n'),
'jnl_m_badtype': ('  слот неизвестного вида (освобождён): ', '  un hueco de tipo desconocido (liberado): '),
'jnl_m_orphan': ('  его папки нет (перенесён в /): ', '  su carpeta no existe (movido a /): '),
'jnl_m_badlink': ('  цепочка обрывается (укорочена): ', '  su cadena se rompe (acortada): '),
'jnl_m_crossed': ('  делит секторы с другим файлом (укорочен): ', '  comparte sectores con otro archivo (acortado): '),
'jnl_m_freeused': ('  занимает секторы, отмеченные свободными (отмечены): ', '  usa sectores marcados libres (marcados): '),
'jnl_m_size': ('  неверный размер (исправлен): ', '  tamaño incorrecto (corregido): '),
'jnl_m_lost': ('  секторы, которые ничьи (освобождены): ', '  sectores que no son de nadie (liberados): '),
'jnl_m_sum1': (' файлов, ', ' archivos, '),
'jnl_m_sum2': (' папок, ', ' carpetas, '),
'jnl_m_sum3': (' секторов данных.\n', ' sectores de datos.\n'),
'jnl_m_ok': ('Ошибок не найдено.\n', 'No se encontraron problemas.\n'),
'jnl_m_found': (' ошибок - fsck fix исправит их.\n', ' problemas - fsck fix los arregla.\n'),
'jnl_m_fixed': (' ошибок исправлено.\n', ' problemas arreglados.\n'),
'jnl_m_journal': ('Журнал: включён, записей с загрузки: ', 'Diario: activo, escrituras desde el arranque: '),
'jnl_m_journal2': ('.\n', '.\n'),
'jnl_m_rep1': ('Журнал: прерванная запись завершена (', 'Diario: se terminó una escritura interrumpida ('),
'jnl_m_rep2': (' секторов).\n', ' sectores).\n'),
'help_l60': ('новая / другая консоль / закрыть эту', 'nueva consola / cambiar / cerrar esta'),
'help_l54': ('Tiny BASIC (можно загрузить и запустить n)', 'Tiny BASIC (puede cargar y ejecutar n)'),
# ---- the desktop ----
'dk_title_terminal': ('Терминал', 'Terminal'),
'dk_title_clock': ('Часы', 'Reloj'),
'dk_title_pictures': ('Картинки', 'Imágenes'),
'dk_title_system': ('Система', 'Sistema'),
'dk_title_files': ('Файлы', 'Archivos'),
'dk_title_tasks': ('Задачи', 'Tareas'),
'dk_title_mixer': ('Микшер', 'Mezclador'),
'dk_title_program': ('Программа', 'Programa'),
'dk_menu_programs': ('Программы', 'Programas'),
'dk_menu_logout': ('Выйти из системы', 'Cerrar sesión'),
'dk_menu_restart': ('Перезагрузка', 'Reiniciar'),
'dk_menu_shutdown': ('Выключение', 'Apagar'),
'dk_menu_exit': ('Выход в консоль', 'Salir a la consola'),
'dk_msg_watermark': ('Рабочий стол LexOS', 'Escritorio LexOS'),
'dk_ctx_l_open': ('Открыть', 'Abrir'),
'dk_ctx_l_rename': ('Переименовать...', 'Renombrar...'),
'dk_ctx_l_copy': ('Копировать в...', 'Copiar a...'),
'dk_ctx_l_delete': ('Удалить', 'Eliminar'),
'dk_ctx_l_props': ('Свойства', 'Propiedades'),
'dk_ctx_l_newdir': ('Новая папка...', 'Nueva carpeta...'),
'dk_ctx_l_selall': ('Выделить всё', 'Seleccionar todo'),
'dk_ctx_l_forever': ('Удалить навсегда', 'Borrar del todo'),
'dk_ctx_l_empty': ('Очистить корзину', 'Vaciar papelera'),
'dk_fm_trashed': ('Перемещено в корзину (/TRASH).', 'Movido a la papelera (/TRASH).'),
'dk_fm_is_folder': (' - папка', ' - una carpeta'),
'dk_fm_bytes': (' байт', ' bytes'),
'dk_cal_weekdays': ('Пн  Вт  Ср  Чт  Пт  Сб  Вс', 'Lu  Ma  Mi  Ju  Vi  Sá  Do'),
'dk_m1': ('Январь', 'Enero'), 'dk_m2': ('Февраль', 'Febrero'), 'dk_m3': ('Март', 'Marzo'),
'dk_m4': ('Апрель', 'Abril'), 'dk_m5': ('Май', 'Mayo'), 'dk_m6': ('Июнь', 'Junio'),
'dk_m7': ('Июль', 'Julio'), 'dk_m8': ('Август', 'Agosto'), 'dk_m9': ('Сентябрь', 'Septiembre'),
'dk_m10': ('Октябрь', 'Octubre'), 'dk_m11': ('Ноябрь', 'Noviembre'), 'dk_m12': ('Декабрь', 'Diciembre'),
'dk_msg_scrolled': ('прокручено назад', 'desplazado atrás'),
'dk_prog_none': ('(нет программ)', '(sin programas)'),
'dk_msg_find': ('Найти:', 'Buscar:'),
'dk_msg_find_hint': ('Поиск', 'Buscar'),
'dk_msg_loading': ('Ищу файлы .BMP...', 'Buscando archivos .BMP...'),
'dk_msg_no_pictures': ('В этой папке нет файлов .BMP.', 'No hay archivos .BMP en esta carpeta.'),
'dk_sys_title': ('LexOS - хобби-ОС на NASM', 'LexOS - un SO hecho en NASM'),
'dk_sys_uptime': ('Работает ', 'Encendido hace '),
'dk_sys_memory': ('Память: 128 МБ', 'Memoria: 128 MB'),
'dk_sys_consoles': ('Консолей: ', 'Consolas: '),
'dk_sys_ip': ('Адрес: ', 'Dirección: '),
'dk_sys_no_ip': ('(сети пока нет)', '(aún sin red)'),
'dk_sys_hint': ('Команда `desktop` ещё раз - выход.', 'Escribe `desktop` otra vez para salir.'),
'dk_mix_master': ('Общая', 'General'),
'dk_mix_silent': ('Ничего не играет.', 'No suena nada.'),
'dk_fm_up': ('Вверх', 'Subir'),
'dk_fm_items': (' шт. Двойной клик - открыть, перетащить на папку - переместить.', ' elementos. Doble clic abre, arrastrar a una carpeta mueve.'),
'dk_fm_busy': ('Терминал занят - попробуйте чуть позже.', 'La terminal está ocupada - inténtalo en un momento.'),
'dk_fm_full': ('Терминал занят, и места для ещё одного нет.', 'La terminal está ocupada y no cabe otra.'),
'dk_fm_waiting': ('Прочитаю папку, когда терминал освободится...', 'Leeré la carpeta cuando la terminal quede libre...'),
'dk_fm_moved': ('Перемещено.', 'Movido.'),
'dk_fm_taken': ('Там уже есть такое имя.', 'Ya hay uno con ese nombre allí.'),
'dk_fm_into_itself': ('Папку нельзя положить в неё саму.', 'Una carpeta no puede ir dentro de sí misma.'),
'dk_fm_find_hint': ('Поиск', 'Buscar'),
'dk_fm_s_name': ('Порядок: имя', 'Orden: nombre'),
'dk_fm_s_size': ('Порядок: размер', 'Orden: tamaño'),
'dk_fm_s_type': ('Порядок: тип', 'Orden: tipo'),
'dk_task_header': ('PID  ИМЯ                  СОСТОЯН.  ПРИОР.   ПАМЯТЬ    ЦП',
                   'PID  NOMBRE               ESTADO    PRIOR.   MEMORIA   CPU'),
'dk_task_cpu': ('ЦП ', 'CPU '),
'dk_task_mem': ('Память ', 'Memoria '),
'dk_task_mem_of': (' из 128 МБ занято', ' de 128 MB en uso'),
'dk_task_prio': ('Приоритет:', 'Prioridad:'),
'dk_task_prio_set': ('Приоритет задан.', 'Prioridad cambiada.'),
'dk_task_prio_no': ('Приоритет самого рабочего стола не меняется.', 'La prioridad del escritorio no cambia.'),
'dk_prio_low': ('Низкий', 'Baja'),
'dk_prio_normal': ('Обычный', 'Normal'),
'dk_prio_high': ('Высокий', 'Alta'),
'dk_task_end': ('Завершить', 'Terminar'),
'dk_task_ended': ('Завершено.', 'Terminada.'),
'dk_task_cant': ('Эту нельзя (консоль или рабочий стол).', 'Esa no (una consola o el escritorio).'),
'dkc_msg_copied': ('Скопировано: ', 'Copiado: '),
'dkc_msg_chars': (' символов (Ctrl+V - вставить)', ' caracteres (Ctrl+V pega)'),
'dk_msg_theme': ('Тема:', 'Tema:'),
'dk_msg_sounds': ('Звуки:', 'Sonidos:'),
'dk_msg_on': ('Вкл', 'Sí'),
'dk_msg_off': ('Выкл', 'No'),
'dk_msg_backdrop': ('Фон', 'Fondo'),
'dk_th_classic': ('Обычная', 'Clásico'),
'dk_th_dark': ('Тёмная', 'Oscuro'),
'dk_th_light': ('Светлая', 'Claro'),
'dk_th_forest': ('Лес', 'Bosque'),
'dk_th_plum': ('Слива', 'Ciruela'),
'dk_bd_theme': ('Тема', 'Tema'),
'dk_bd_night': ('Ночь', 'Noche'),
'dk_bd_sunset': ('Закат', 'Ocaso'),
'dk_bd_ocean': ('Океан', 'Océano'),
'dk_bd_slate': ('Сланец', 'Pizarra'),
'dkt_d0': ('Воскресенье', 'Domingo'), 'dkt_d1': ('Понедельник', 'Lunes'),
'dkt_d2': ('Вторник', 'Martes'), 'dkt_d3': ('Среда', 'Miércoles'),
'dkt_d4': ('Четверг', 'Jueves'), 'dkt_d5': ('Пятница', 'Viernes'), 'dkt_d6': ('Суббота', 'Sábado'),
'dkt_msg_volume': ('Громкость ', 'Volumen '),
'dkt_msg_muted': ('Без звука', 'Silencio'),
'dkt_msg_caps_on': ('Caps Lock включён', 'Bloq Mayús activado'),
'dkt_msg_caps_off': ('Caps Lock выключен', 'Bloq Mayús desactivado'),
'dkx_l_minimize': ('Свернуть', 'Minimizar'),
'dkx_l_restore': ('Показать', 'Mostrar'),
'dkx_l_maximize': ('Развернуть', 'Maximizar'),
'dkx_l_unmax': ('Обычный размер', 'Tamaño normal'),
'dkx_l_close': ('Закрыть', 'Cerrar'),
'dkx_l_newterm': ('Новый терминал', 'Nueva terminal'),
'dkx_l_files': ('Файлы', 'Archivos'),
'dkx_l_tasks': ('Задачи', 'Tareas'),
'dkx_l_system': ('Система', 'Sistema'),
'dkx_l_arrange': ('Упорядочить значки', 'Ordenar iconos'),
'dkx_l_backdrop': ('Следующий фон', 'Siguiente fondo'),
'dkx_l_fcopy': ('Копировать', 'Copiar'),
'dkx_l_fcut': ('Вырезать', 'Cortar'),
'dkx_l_fpaste': ('Вставить', 'Pegar'),
'dkx_l_catfeed': ('Покормить Lex', 'Alimentar a Lex'),
'dkx_l_catpet': ('Погладить Lex', 'Acariciar a Lex'),
'dkx_l_catplay': ('Поиграть с Lex', 'Jugar con Lex'),
'dkx_l_cathow': ('Как дела у Lex?', '¿Cómo está Lex?'),
'cat_msg_nom': ('Ням-ням!', '¡Ñam, ñam!'),
'cat_msg_full': ('Lex не голоден', 'Lex no tiene hambre'),
'cat_msg_play': ('Lex ловит курсор!', '¡Lex persigue el puntero!'),
'cat_msg_too_sleepy': ('Lex слишком сонный для игр', 'Lex tiene demasiado sueño'),
'cat_msg_hungry': ('Lex голоден...', 'Lex tiene hambre...'),
'cat_msg_lonely': ('Lex скучает...', 'Lex se siente solo...'),
'cat_msg_sleepy': ('Lex хочет спать...', 'Lex tiene sueño...'),
'cat_l_food': ('Сытость', 'Comida'),
'cat_l_joy': ('Радость', 'Alegría'),
'cat_l_energy': ('Бодрость', 'Energía'),
'dkx_l_cathide': ('Спрятать Lex', 'Ocultar a Lex'),
'dkx_l_catshow': ('Позвать Lex', 'Llamar a Lex'),
'dkx_msg_fc_copied': ('Скопировано: ', 'Copiados: '),
'dkx_msg_fc_cut': ('Вырезано: ', 'Cortados: '),
'dkx_msg_fc_hint': (' - Ctrl+V в другой папке вставит', ' - Ctrl+V en otra carpeta los pega'),
'dkx_msg_fc_pasted': ('Вставлено: ', 'Pegados: '),
'dkx_msg_bye_off': ('LexOS выключается...', 'LexOS se está apagando...'),
'dkx_msg_bye_restart': ('LexOS перезагружается...', 'LexOS se está reiniciando...'),
'dkx_msg_bye_lex': ('Пока! До скорой встречи.  - Lex', '¡Adiós! Hasta pronto.  - Lex'),
'cat_msg_meow': ('Мяу!', '¡Miau!'),
# ---- the first boot, the login ----
'wl_msg_tagline': ('хобби-операционная система на ассемблере', 'un sistema operativo hecho en ensamblador'),
'wl_msg_hi': ('Привет, ', '¡Hola, '),
'wl_msg_starting': ('Рабочий стол уже в пути...', 'Tu escritorio ya viene...'),
'wl_msg_back': ('С возвращением, ', 'Hola de nuevo, '),
'wl_msg_login': ('Ваш пароль, затем Enter', 'Tu contraseña y Enter'),
'wl_msg_wrong': ('Не тот - попробуйте ещё', 'No es esa - prueba otra vez'),
'wl_msg_enter': ('Без пароля - нажмите Enter', 'Sin contraseña - pulsa Enter'),
'wl_msg_sign_in': ('Войти', 'Entrar'),
# ---- neofetch, uptime, lex ----
'nf_msg_up': ('работает ', 'encendido '),
'nf_msg_consoles': (', консолей: ', ', consolas: '),
'nf_msg_tasks_n': (', задач: ', ', tareas: '),
'nf_msg_tasks': (' задач', ' tareas'),
'nf_msg_of': (' из ', ' de '),
'nf_msg_kb': (' КБ', ' KB'),
'nf_msg_mb': (' МБ', ' MB'),
'nf_msg_backdrop': (' фон', ' de fondo'),
'nf_lbl_os': ('ОС: ', 'SO: '),
'nf_lbl_kernel': ('Ядро: ', 'Núcleo: '),
'nf_lbl_uptime': ('Работает: ', 'Encendido: '),
'nf_lbl_shell': ('Оболочка: ', 'Shell: '),
'nf_lbl_display': ('Экран: ', 'Pantalla: '),
'nf_lbl_theme': ('Тема: ', 'Tema: '),
'nf_lbl_lang': ('Раскладки: ', 'Teclados: '),
'nf_lbl_ui': ('Система: ', 'Sistema: '),
'nf_val_en': ('английская', 'inglés'),
'nf_w_ru': (' + русская', ' + ruso'),
'nf_w_es': (' + испанская', ' + español'),
'nf_lbl_cpu': ('ЦП: ', 'CPU: '),
'nf_lbl_memory': ('Память: ', 'Memoria: '),
'nf_lbl_consoles': ('Консоли: ', 'Consolas: '),
'nf_lbl_cat': ('Кот: ', 'Gato: '),
'nf_val_os': ('LexOS x86 (32 бита, защищённый режим)', 'LexOS x86 (32 bits, modo protegido)'),
'nf_val_text': ('текст 80x25', 'texto 80x25'),
'nf_val_desktop': ('1024x768x32, рабочий стол', '1024x768x32, escritorio'),
'nf_val_cat': ('Lex (мурчит)', 'Lex (ronroneando)'),
'lex_s0': ('Мяу! Не забудь сохранить файл.', '¡Miau! No olvides guardar el archivo.'),
'lex_s1': ('Мрр... ядро тёплое, посплю на нём.', 'Rrr... el núcleo está calentito, dormiré encima.'),
'lex_s2': ('Уже время ужина?', '¿Ya es la hora de cenar?'),
'lex_s3': ('Я уронил байт со стола. Прости.', 'Tiré un byte de la mesa. Perdón.'),
'lex_s4': ('Набери help, если заблудился. Я вот никогда.', 'Escribe help si te pierdes. Yo nunca.'),
'lex_s5': ('Написан на ассемблере, как все хорошие коты.', 'Escrito en ensamblador, como todo buen gato.'),
'lex_s6': ('Мрр. Погладь меня, а потом запусти neofetch.', 'Rrr. Acaríciame y luego ejecuta neofetch.'),
'lex_s7': ('Гонялся за курсором мыши. Удрал.', 'Perseguí el puntero del ratón. Se escapó.'),
'lex_s8': ('Девять консолей, девять жизней.', 'Nueve consolas, nueve vidas.'),
'lex_s9': ('Мяу-мяу! (Это значит: классная ОС.)', '¡Miau miau! (Significa: qué buen SO.)'),
}

def english():
    """label -> its bytes (to the 0), from every db in src/*.asm"""
    found = {}
    for name in sorted(os.listdir(os.path.join(ROOT, 'src'))):
        if not name.endswith('.asm'):
            continue
        lines = open(os.path.join(ROOT, 'src', name), encoding='latin-1').read().split('\n')
        for i, line in enumerate(lines):
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+db\s+(.*)$', line)
            if not m or m.group(1) not in TR:
                continue
            data, rest, j = [], m.group(2), i
            while True:
                done = False
                for item in split_items(strip_comment(rest)):
                    if item[0] in '"\'':
                        data += list(item[1:-1].encode('latin-1'))
                    else:
                        v = int(item, 0)
                        if v == 0:
                            done = True
                            break
                        data.append(v)
                if done:
                    break
                j += 1
                m2 = re.match(r'^\s+db\s+(.*)$', lines[j])
                if not m2:
                    break
                rest = m2.group(1)
            found[m.group(1)] = bytes(data)
    return found


def strip_comment(s):
    q = None
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = None
        elif c in '"\'':
            q = c
        elif c == ';':
            return s[:i]
    return s


def split_items(s):
    items, cur, q = [], '', None
    for c in s:
        if q:
            cur += c
            if c == q:
                q = None
        elif c in '"\'':
            q = c
            cur += c
        elif c == ',':
            items.append(cur.strip())
            cur = ''
        else:
            cur += c
    if cur.strip():
        items.append(cur.strip())
    return items


def fnv(b):
    h = 2166136261
    for x in b:
        h = ((h ^ x) * 16777619) & 0xFFFFFFFF
    return h


def main():
    data = open(os.path.join(ROOT, 'src', 'data.asm')).read()
    helps = dict(re.findall(r'^(help_l\d+) db "([^"]*)"', data, re.M))
    eng = english()
    entries = {}
    for label, (ru, es) in TR.items():
        if label not in eng:
            sys.exit('mklang: no English %s in src/' % label)
        if label in helps and ' - ' in helps[label] and not ru.startswith(' '):
            head = helps[label].split(' - ', 1)[0]
            ru = head + ' - ' + ru + '\\n'
            es = head + ' - ' + es + '\\n'
        r, e = bytes(encode(ru, 'ru')), bytes(encode(es, 'es'))
        for lang, b in (('ru', r), ('es', e)):
            if label.startswith('help_l') and len(b) - 2 > 79:
                print('mklang: %s (%s) is %d long' % (label, lang, len(b) - 2))
        h = fnv(eng[label])
        if h in entries and entries[h][0] != eng[label]:
            sys.exit('mklang: %s: a hash that\'s taken' % label)
        entries[h] = (eng[label], r, e)
    keys = sorted(entries)
    head = 8 + 12 * len(keys)
    table, blob = b'', b''
    for h in keys:
        _, r, e = entries[h]
        ro = head + len(blob)
        blob += r + b'\0'
        eo = head + len(blob)
        blob += e + b'\0'
        table += h.to_bytes(4, 'little') + ro.to_bytes(4, 'little') + eo.to_bytes(4, 'little')
    out = b'LXTR' + len(keys).to_bytes(4, 'little') + table + blob
    path = os.path.join(ROOT, 'disk', 'SYSTEM', 'LANG.DAT')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(out)
    print('mklang: %d strings, %d bytes' % (len(keys), len(out)))


main()
