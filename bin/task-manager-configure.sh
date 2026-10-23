#!/bin/bash
# Adds or removes one of the Task Manager's optional Hyprland snippets, after
# explaining exactly what will change and asking the user. The card opens it
# in a terminal; nothing is written without a "yes" typed here.
#
#   task-manager-configure.sh <show|reset|veil> <apply|remove>
#
# What it touches, and nothing else:
#   ~/.config/hypr/task-manager-<snippet>.lua   a file of its own (created/deleted)
#   ~/.config/hypr/hyprland.lua                 one require("hypr.task-manager-<snippet>")
#                                               line (added/removed), after a backup
# Hyprland reloads its config when these files change.
set -euo pipefail
umask 077

what="${1:-}"
action="${2:-}"
case "$what" in show | reset | veil) ;; *) echo "usage: $0 <show|reset|veil> <apply|remove>" >&2; exit 2 ;; esac
case "$action" in apply | remove) ;; *) echo "usage: $0 <show|reset|veil> <apply|remove>" >&2; exit 2 ;; esac

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LANG_ID="${LANGUAGE:-${LANG:-en}}"
LANG_ID="${LANG_ID%%[:._]*}"
# Same languages as the card's i18n.json; anything else falls back to English.
# say <en> <es> <pt> <fr> <de>
say() {
  case "$LANG_ID" in
    es) printf '%s\n' "$2" ;;
    pt) printf '%s\n' "$3" ;;
    fr) printf '%s\n' "$4" ;;
    de) printf '%s\n' "$5" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

HYPR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
MAIN="$HYPR/hyprland.lua"
case "$what" in
  show) MOD="task-manager-bindings" ;;
  reset) MOD="task-manager-reset-bindings" ;;
  veil) MOD="task-manager-veil" ;;
esac
FILE="$HYPR/$MOD.lua"
REQUIRE="require(\"hypr.$MOD\")"

# The reset bind runs the light engine (always present, nothing to build);
# its path is spliced into a Lua string, so it must need no escaping.
LAUNCHER="$DIR/task-manager-light.sh"
if [ "$what" = reset ] && [[ ! "$LAUNCHER" =~ ^/[A-Za-z0-9._/+@-]+$ ]]; then
  say "The plugin path has characters that cannot go into the bind safely; nothing was changed." \
      "La ruta del plugin tiene caracteres que no pueden ir en el atajo de forma segura; no se cambió nada." \
      "O caminho do plugin tem caracteres que não podem ir no atalho com segurança; nada foi alterado." \
      "Le chemin du plugin contient des caractères qui ne peuvent pas aller dans le raccourci en toute sécurité ; rien n'a été modifié." \
      "Der Plugin-Pfad enthält Zeichen, die nicht sicher in das Tastenkürzel passen; es wurde nichts geändert."
  exit 1
fi

content() {
  echo "-- Added by the Task Manager plugin (bin/task-manager-configure.sh) at your request."
  echo "-- Remove it from the card's gear panel, or delete this file and the"
  echo "-- $REQUIRE line in hyprland.lua."
  case "$what" in
    show)
      echo 'hl.unbind("SUPER + SHIFT + T")'
      echo 'o.bind("SUPER + SHIFT + T", "Task Manager", "omarchy-shell shell toggle io.github.avillagran.omarchy-task-manager")'
      ;;
    reset)
      echo 'hl.unbind("SUPER + CTRL + SHIFT + Delete")'
      echo "o.bind(\"SUPER + CTRL + SHIFT + Delete\", \"Force reset shell\", \"$LAUNCHER shell-reset force\")"
      ;;
    veil)
      cat <<'EOF'
hl.window_rule({
  name = "tm-veil-base",
  match = { class = "^org.quickshell$" },
  float = true,
  no_initial_focus = true,
  no_anim = true,
  border_size = 0,
  no_shadow = true,
  no_follow_mouse = true,
  decorate = false,
})
EOF
      ;;
  esac
}

describe() {
  case "$what" in
    show) say "Keyboard shortcut SUPER+SHIFT+T to open and close the Task Manager (it replaces whatever SUPER+SHIFT+T did before)." \
              "Atajo SUPER+SHIFT+T para abrir y cerrar el Administrador de tareas (reemplaza lo que hiciera antes SUPER+SHIFT+T)." \
              "Atalho SUPER+SHIFT+T para abrir e fechar o Gerenciador de tarefas (substitui o que SUPER+SHIFT+T fazia antes)." \
              "Raccourci SUPER+SHIFT+T pour ouvrir et fermer le Gestionnaire des tâches (il remplace ce que faisait SUPER+SHIFT+T)." \
              "Tastenkürzel SUPER+SHIFT+T zum Öffnen und Schließen des Task-Managers (ersetzt die bisherige Belegung von SUPER+SHIFT+T)." ;;
    reset) say "Emergency shortcut SUPER+CTRL+SHIFT+Delete: force-restarts a frozen Omarchy shell, even when it cannot be clicked." \
               "Atajo de emergencia SUPER+CTRL+SHIFT+Supr: fuerza el reinicio del shell de Omarchy cuando está congelado y no responde a clics." \
               "Atalho de emergência SUPER+CTRL+SHIFT+Delete: força o reinício do shell do Omarchy quando ele trava e não responde a cliques." \
               "Raccourci d'urgence SUPER+CTRL+SHIFT+Suppr : force le redémarrage du shell Omarchy quand il est figé et ne répond plus aux clics." \
               "Notfall-Tastenkürzel SUPER+STRG+SHIFT+Entf: startet die Omarchy-Shell zwangsweise neu, wenn sie hängt und nicht auf Klicks reagiert." ;;
    veil) say "Window rule that lets the grey veils float exactly over paused apps (needed before turning veils on)." \
              "Regla de ventana para que los velos grises floten justo sobre las apps pausadas (necesaria antes de activar los velos)." \
              "Regra de janela para que os véus cinza flutuem exatamente sobre os apps pausados (necessária antes de ativar os véus)." \
              "Règle de fenêtre pour que les voiles gris flottent exactement au-dessus des apps en pause (nécessaire avant d'activer les voiles)." \
              "Fensterregel, damit die grauen Schleier genau über pausierten Apps schweben (nötig, bevor die Schleier aktiviert werden)." ;;
  esac
}

has_require() { [ -f "$MAIN" ] && grep -qxF "$REQUIRE" "$MAIN"; }
applied() { [ -f "$FILE" ] && has_require; }

confirm() {
  echo
  if command -v gum >/dev/null 2>&1; then
    gum confirm --default=false "$(say "Apply these changes?" "¿Aplicar estos cambios?" "Aplicar estas alterações?" \
                                     "Appliquer ces modifications ?" "Diese Änderungen anwenden?")"
  else
    local reply
    read -r -p "$(say "Apply these changes? [y/N] " "¿Aplicar estos cambios? [s/N] " "Aplicar estas alterações? [s/N] " \
                      "Appliquer ces modifications ? [o/N] " "Diese Änderungen anwenden? [j/N] ")" reply
    [[ "$reply" =~ ^[sSyYoOjJ]$ ]]
  fi
}

# Replace a file atomically, keeping its permissions when it exists.
write_atomic() { # $1=target, content on stdin
  local tmp
  tmp=$(mktemp "$1.tmp.XXXXXX")
  cat >"$tmp"
  [ -e "$1" ] && chmod --reference="$1" "$tmp"
  mv -f -- "$tmp" "$1"
}

refuse_symlinks() {
  local f
  for f in "$MAIN" "$FILE"; do
    if [ -L "$f" ]; then
      say "$f is a symlink (a dotfiles manager?). Not touching it: add the lines yourself, they are shown above." \
          "$f es un enlace simbólico (¿un gestor de dotfiles?). No lo toco: agrega tú las líneas, están arriba." \
          "$f é um link simbólico (um gerenciador de dotfiles?). Não vou mexer: adicione você as linhas, estão acima." \
          "$f est un lien symbolique (un gestionnaire de dotfiles ?). Je n'y touche pas : ajoutez vous-même les lignes ci-dessus." \
          "$f ist ein symbolischer Link (ein Dotfiles-Manager?). Ich fasse ihn nicht an: füge die Zeilen oben selbst hinzu."
      exit 1
    fi
  done
  if [ ! -f "$MAIN" ]; then
    say "$MAIN does not exist; nothing was changed." "$MAIN no existe; no se cambió nada." \
        "$MAIN não existe; nada foi alterado." "$MAIN n'existe pas ; rien n'a été modifié." \
        "$MAIN existiert nicht; es wurde nichts geändert."
    exit 1
  fi
}

echo
describe
echo

if [ "$action" = apply ]; then
  if applied; then
    say "It is already applied ($FILE). Nothing to do." "Ya está aplicado ($FILE). No hay nada que hacer." \
        "Já está aplicado ($FILE). Nada a fazer." "C'est déjà appliqué ($FILE). Rien à faire." \
        "Ist bereits angewendet ($FILE). Nichts zu tun."
    exit 0
  fi
  say "What will change:" "Qué se va a cambiar:" "O que vai mudar:" "Ce qui va changer :" "Was sich ändert:"
  say "  1. Create $FILE with:" "  1. Crear $FILE con:" "  1. Criar $FILE com:" "  1. Créer $FILE avec :" \
      "  1. $FILE anlegen mit:"
  echo
  content | sed 's/^/       /'
  echo
  if has_require; then
    say "  2. hyprland.lua already loads it; it stays as it is." "  2. hyprland.lua ya lo carga; queda igual." \
        "  2. hyprland.lua já o carrega; fica como está." "  2. hyprland.lua le charge déjà ; il reste tel quel." \
        "  2. hyprland.lua lädt sie bereits; bleibt unverändert."
  else
    say "  2. Add this line at the end of $MAIN:" "  2. Agregar esta línea al final de $MAIN:" \
        "  2. Adicionar esta linha no final de $MAIN:" "  2. Ajouter cette ligne à la fin de $MAIN :" \
        "  2. Diese Zeile am Ende von $MAIN hinzufügen:"
    echo "       $REQUIRE"
    say "     (a backup copy is saved next to it first)" "     (antes se guarda una copia de respaldo al lado)" \
        "     (antes é salva uma cópia de segurança ao lado)" "     (une copie de sauvegarde est d'abord enregistrée à côté)" \
        "     (vorher wird daneben eine Sicherungskopie abgelegt)"
  fi
  say "  Hyprland reloads its configuration; nothing else is touched and nothing runs as root." \
      "  Hyprland recarga su configuración; no se toca nada más y nada corre como root." \
      "  O Hyprland recarrega sua configuração; nada mais é tocado e nada roda como root." \
      "  Hyprland recharge sa configuration ; rien d'autre n'est touché et rien ne tourne en root." \
      "  Hyprland lädt seine Konfiguration neu; sonst wird nichts angefasst und nichts läuft als root."
  refuse_symlinks
  if ! confirm; then
    echo
    say "Cancelled: nothing was changed." "Cancelado: no se cambió nada." "Cancelado: nada foi alterado." \
        "Annulé : rien n'a été modifié." "Abgebrochen: es wurde nichts geändert."
    exit 130
  fi
  content | write_atomic "$FILE"
  if ! has_require; then
    backup="$MAIN.task-manager-backup-$(date +%Y%m%d-%H%M%S)"
    cp -p -- "$MAIN" "$backup"
    { cat -- "$MAIN"; [ -z "$(tail -c1 -- "$MAIN")" ] || echo; echo "$REQUIRE"; } | write_atomic "$MAIN"
    say "Backup: $backup" "Respaldo: $backup" "Cópia de segurança: $backup" "Sauvegarde : $backup" \
        "Sicherung: $backup"
  fi
else
  if [ ! -f "$FILE" ] && ! has_require; then
    say "It is not applied. Nothing to do." "No está aplicado. No hay nada que hacer." \
        "Não está aplicado. Nada a fazer." "Ce n'est pas appliqué. Rien à faire." "Ist nicht angewendet. Nichts zu tun."
    exit 0
  fi
  say "What will change:" "Qué se va a cambiar:" "O que vai mudar:" "Ce qui va changer :" "Was sich ändert:"
  [ -f "$FILE" ] && { say "  1. Delete $FILE" "  1. Borrar $FILE" "  1. Apagar $FILE" "  1. Supprimer $FILE" \
                         "  1. $FILE löschen"; }
  has_require && { say "  2. Remove this line from $MAIN (after a backup copy):" \
                       "  2. Quitar esta línea de $MAIN (después de una copia de respaldo):" \
                       "  2. Remover esta linha de $MAIN (depois de uma cópia de segurança):" \
                       "  2. Retirer cette ligne de $MAIN (après une copie de sauvegarde) :" \
                       "  2. Diese Zeile aus $MAIN entfernen (nach einer Sicherungskopie):"
                   echo "       $REQUIRE"; }
  refuse_symlinks
  if ! confirm; then
    echo
    say "Cancelled: nothing was changed." "Cancelado: no se cambió nada." "Cancelado: nada foi alterado." \
        "Annulé : rien n'a été modifié." "Abgebrochen: es wurde nichts geändert."
    exit 130
  fi
  # The require line goes first: a require of a missing file would break
  # the Hyprland config.
  if has_require; then
    backup="$MAIN.task-manager-backup-$(date +%Y%m%d-%H%M%S)"
    cp -p -- "$MAIN" "$backup"
    grep -vxF -- "$REQUIRE" "$MAIN" | write_atomic "$MAIN" || true
    say "Backup: $backup" "Respaldo: $backup" "Cópia de segurança: $backup" "Sauvegarde : $backup" \
        "Sicherung: $backup"
  fi
  rm -f -- "$FILE"
fi

hyprctl reload >/dev/null 2>&1 || true
echo
say "Done." "Listo." "Pronto." "Terminé." "Fertig."
