;;; gterm.el --- Terminal emulator for Emacs using libghostty -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rob Christie
;; Author: Rob Christie
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1"))
;; Keywords: terminals, processes
;; URL: https://github.com/rwc9u/emacs-libgterm

;;; Commentary:

;; gterm is a terminal emulator for Emacs built on libghostty-vt, the
;; terminal emulation library extracted from the Ghostty terminal emulator.
;;
;; This provides a similar experience to emacs-libvterm but uses Ghostty's
;; terminal engine which offers better Unicode support, SIMD-optimized
;; parsing, text reflow on resize, and Kitty graphics protocol support.
;;
;; Usage:
;;   M-x gterm

;;; Code:

(require 'cl-lib)

;; ── Module loading ──────────────────────────────────────────────────────

(defvar gterm-source-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the gterm source files.")

(defvar gterm-module-path
  (expand-file-name
   (concat "zig-out/lib/libgterm-module" module-file-suffix)
   gterm-source-dir)
  "Path to the compiled gterm dynamic module.")

(defcustom gterm-always-compile-module nil
  "If non-nil, compile the gterm module without prompting."
  :type 'boolean
  :group 'gterm)

(defun gterm-module-compile ()
  "Compile the gterm dynamic module.
Automatically clones Ghostty and applies the build patch if needed."
  (interactive)
  (let ((default-directory gterm-source-dir)
        (buf (get-buffer-create "*gterm-compile*")))
    (with-current-buffer buf (erase-buffer))
    ;; Check for zig
    (unless (executable-find "zig")
      (error "gterm: `zig` not found in PATH. Install Zig 0.15.2+ (https://ziglang.org/download/)"))
    ;; Check for git
    (unless (executable-find "git")
      (error "gterm: `git` not found in PATH"))
    ;; Clone ghostty if needed
    (let ((ghostty-dir (expand-file-name "vendor/ghostty" gterm-source-dir)))
      (unless (file-directory-p ghostty-dir)
        (message "gterm: cloning ghostty (this may take a minute)...")
        (let ((exit-code (call-process "git" nil buf t
                                       "clone" "--depth" "1"
                                       "https://github.com/ghostty-org/ghostty.git"
                                       ghostty-dir)))
          (unless (= exit-code 0)
            (pop-to-buffer buf)
            (error "gterm: failed to clone ghostty"))))
      ;; Apply build patch if not already applied
      (let ((patch-file (expand-file-name "patches/ghostty-build.patch" gterm-source-dir)))
        (when (and (file-exists-p patch-file)
                   (= 0 (call-process "git" nil nil nil
                                       "-C" ghostty-dir
                                       "diff" "--quiet" "build.zig")))
          ;; build.zig has no local changes — apply patch
          (message "gterm: applying ghostty build patch...")
          (call-process "git" nil buf t
                        "-C" ghostty-dir
                        "apply" patch-file))))
    ;; Compile
    (message "gterm: compiling module with `zig build`...")
    (let ((exit-code (call-process "zig" nil buf t "build")))
      (if (= exit-code 0)
          (message "gterm: module compiled successfully")
        (pop-to-buffer buf)
        (error "gterm: compilation failed (exit code %d). See *gterm-compile* buffer" exit-code)))))

(unless (featurep 'gterm-module)
  (unless (file-exists-p gterm-module-path)
    (if (or gterm-always-compile-module
            (y-or-n-p "gterm module not compiled. Compile now? "))
        (gterm-module-compile)
      (error "gterm: module not found at %s" gterm-module-path)))
  (module-load gterm-module-path))

;; ── Customization ───────────────────────────────────────────────────────

(defgroup gterm nil
  "Terminal emulator using libghostty."
  :group 'terminals)

(defcustom gterm-shell "/bin/zsh"
  "Shell program to run in gterm."
  :type 'string
  :group 'gterm)

(defcustom gterm-term-environment-variable "xterm-256color"
  "Value of TERM environment variable for the shell process."
  :type 'string
  :group 'gterm)

(defcustom gterm-max-scrollback 10000
  "Maximum number of scrollback lines."
  :type 'integer
  :group 'gterm)

;; ── Internal state ──────────────────────────────────────────────────────

(defvar-local gterm--term nil
  "The gterm terminal handle for this buffer.")

(defvar-local gterm--process nil
  "The shell process for this buffer.")

(defvar-local gterm--width 80
  "Current terminal width in columns.")

(defvar-local gterm--refresh-timer nil
  "Timer for batched refresh.")

(defvar-local gterm--needs-refresh nil
  "Non-nil when a refresh is pending.")

(defvar-local gterm--scrollback-p nil
  "Non-nil when viewport is scrolled up from the active area.")

(defvar-local gterm--height 24
  "Current terminal height in rows.")

(defvar-local gterm--rendered nil
  "Non-nil after the first full render has been done.")

;; ── Buffer rendering ────────────────────────────────────────────────────

(defun gterm--refresh ()
  "Refresh the buffer with current terminal content.
Uses incremental rendering after the first full render."
  (when gterm--term
    (let* ((inhibit-read-only t)
           (cursor-pos
            (if (and gterm--rendered
                     (fboundp 'gterm-render-dirty))
                ;; Incremental: only update dirty rows
                (gterm-render-dirty gterm--term)
              ;; Full render: erase and redraw everything
              (erase-buffer)
              (setq gterm--rendered t)
              (gterm-render gterm--term))))
      (when (integerp cursor-pos)
        (goto-char cursor-pos))
      ;; Update cursor visibility and style from terminal state
      (when (fboundp 'gterm-cursor-info)
        (let* ((info (gterm-cursor-info gterm--term))
               (visible (car info))
               (style (cdr info)))
          (setq-local cursor-type
                      (if visible style nil)))))))

(defun gterm--full-refresh ()
  "Force a full screen re-render (not incremental)."
  (setq gterm--rendered nil)
  (gterm--refresh))

(defun gterm--schedule-refresh ()
  "Schedule a batched refresh.  Coalesces rapid output into one render."
  (unless gterm--needs-refresh
    (setq gterm--needs-refresh t)
    (let ((buf (current-buffer)))
      (setq gterm--refresh-timer
            (run-at-time 0.008 nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (setq gterm--needs-refresh nil
                                     gterm--refresh-timer nil)
                               (gterm--refresh)))))))))

;; ── Process filter ──────────────────────────────────────────────────────

(defun gterm--filter (process output)
  "Process filter: feed shell output into the terminal and refresh.
PROCESS is the shell process. OUTPUT is the raw string."
  (when-let* ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when gterm--term
          (gterm-feed gterm--term output)
          ;; Only auto-scroll to bottom if we were already at bottom
          (unless gterm--scrollback-p
            (when (fboundp 'gterm-scroll-viewport)
              (gterm-scroll-viewport gterm--term 0)))
          ;; Batch refreshes: schedule a refresh if one isn't pending.
          ;; This coalesces rapid output chunks into a single render.
          (gterm--schedule-refresh))))))

(defun gterm--sentinel (process _event)
  "Process sentinel: clean up when the shell exits.
PROCESS is the shell process."
  (when-let* ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert "\n\n[Process terminated]\n"))))))

;; ── Input handling ──────────────────────────────────────────────────────

(defun gterm-send-string (string)
  "Send STRING to the terminal's shell process."
  (when (and gterm--process (process-live-p gterm--process))
    ;; Snap to bottom on any user input
    (when gterm--scrollback-p
      (when (fboundp 'gterm-scroll-viewport)
        (gterm-scroll-viewport gterm--term 0))
      (setq gterm--scrollback-p nil))
    (process-send-string gterm--process string)))

(defun gterm-send-key ()
  "Send the last input key to the shell."
  (interactive)
  (let* ((key (this-command-keys-vector))
         (last-key (aref key (1- (length key))))
         (char (cond
                ((characterp last-key) (char-to-string last-key))
                ((eq last-key 'return) "\r")
                ((eq last-key 'backspace) "\177")
                ((eq last-key 'tab) "\t")
                ((eq last-key 'escape) "\e")
                (t nil))))
    (when char
      (gterm-send-string char))))

(defun gterm-send-return ()
  "Send return key to the shell."
  (interactive)
  (gterm-send-string "\r"))

(defun gterm-send-backspace ()
  "Send backspace to the shell."
  (interactive)
  (gterm-send-string "\177"))

(defun gterm-send-escape ()
  "Send escape to the shell."
  (interactive)
  (gterm-send-string "\e"))

;; ── Ctrl key handling ───────────────────────────────────────────────────

(defun gterm-send-ctrl-key ()
  "Send Ctrl+key for the last input event."
  (interactive)
  (let* ((key (event-basic-type last-input-event))
         (code (when (and (integerp key) (>= key ?a) (<= key ?z))
                 (- key ?a -1))))
    (when code
      (gterm-send-string (string code)))))

;; Keep explicit versions for C-c sub-commands
(defun gterm-send-ctrl-c ()
  "Send Ctrl-C to the shell."
  (interactive)
  (gterm-send-string "\003"))

(defun gterm-send-ctrl-d ()
  "Send Ctrl-D to the shell."
  (interactive)
  (gterm-send-string "\004"))

(defun gterm-send-ctrl-z ()
  "Send Ctrl-Z to the shell."
  (interactive)
  (gterm-send-string "\032"))

;; ── Escape sequence helpers ─────────────────────────────────────────────

(defun gterm--send-escape-seq (seq)
  "Send escape sequence SEQ (without leading ESC) to the shell."
  (gterm-send-string (concat "\e" seq)))

(defun gterm--app-cursor-p ()
  "Return non-nil if terminal is in application cursor keys mode."
  (and gterm--term
       (fboundp 'gterm-cursor-keys-mode)
       (gterm-cursor-keys-mode gterm--term)))

;; ── Arrow keys ──────────────────────────────────────────────────────────

(defun gterm-send-up ()    (interactive) (gterm--send-escape-seq (if (gterm--app-cursor-p) "OA" "[A")))
(defun gterm-send-down ()  (interactive) (gterm--send-escape-seq (if (gterm--app-cursor-p) "OB" "[B")))
(defun gterm-send-right () (interactive) (gterm--send-escape-seq (if (gterm--app-cursor-p) "OC" "[C")))
(defun gterm-send-left ()  (interactive) (gterm--send-escape-seq (if (gterm--app-cursor-p) "OD" "[D")))

;; ── Navigation keys ─────────────────────────────────────────────────────

(defun gterm-send-home ()      (interactive) (gterm--send-escape-seq (if (gterm--app-cursor-p) "OH" "[H")))
(defun gterm-send-end ()       (interactive) (gterm--send-escape-seq (if (gterm--app-cursor-p) "OF" "[F")))
(defun gterm-send-delete ()    (interactive) (gterm--send-escape-seq "[3~"))
(defun gterm-send-insert ()    (interactive) (gterm--send-escape-seq "[2~"))
(defun gterm-send-page-up ()   (interactive) (gterm--send-escape-seq "[5~"))
(defun gterm-send-page-down () (interactive) (gterm--send-escape-seq "[6~"))

;; ── Function keys ───────────────────────────────────────────────────────

(defun gterm-send-f1 ()  (interactive) (gterm--send-escape-seq "OP"))
(defun gterm-send-f2 ()  (interactive) (gterm--send-escape-seq "OQ"))
(defun gterm-send-f3 ()  (interactive) (gterm--send-escape-seq "OR"))
(defun gterm-send-f4 ()  (interactive) (gterm--send-escape-seq "OS"))
(defun gterm-send-f5 ()  (interactive) (gterm--send-escape-seq "[15~"))
(defun gterm-send-f6 ()  (interactive) (gterm--send-escape-seq "[17~"))
(defun gterm-send-f7 ()  (interactive) (gterm--send-escape-seq "[18~"))
(defun gterm-send-f8 ()  (interactive) (gterm--send-escape-seq "[19~"))
(defun gterm-send-f9 ()  (interactive) (gterm--send-escape-seq "[20~"))
(defun gterm-send-f10 () (interactive) (gterm--send-escape-seq "[21~"))
(defun gterm-send-f11 () (interactive) (gterm--send-escape-seq "[23~"))
(defun gterm-send-f12 () (interactive) (gterm--send-escape-seq "[24~"))

;; ── Modified arrow keys ─────────────────────────────────────────────────

(defun gterm-send-S-up ()    (interactive) (gterm--send-escape-seq "[1;2A"))
(defun gterm-send-S-down ()  (interactive) (gterm--send-escape-seq "[1;2B"))
(defun gterm-send-S-right () (interactive) (gterm--send-escape-seq "[1;2C"))
(defun gterm-send-S-left ()  (interactive) (gterm--send-escape-seq "[1;2D"))
(defun gterm-send-C-right () (interactive) (gterm--send-escape-seq "[1;5C"))
(defun gterm-send-C-left ()  (interactive) (gterm--send-escape-seq "[1;5D"))
(defun gterm-send-M-right () (interactive) (gterm--send-escape-seq "[1;3C"))
(defun gterm-send-M-left ()  (interactive) (gterm--send-escape-seq "[1;3D"))

;; ── Paste and Copy ──────────────────────────────────────────────────────

(defun gterm-yank ()
  "Paste the most recent kill ring entry into the terminal.
Uses bracketed paste mode if the terminal has it enabled."
  (interactive)
  (let ((text (current-kill 0 t)))
    (when text
      (gterm--send-paste text))))

(defvar-local gterm--copy-mode nil
  "Non-nil when gterm is in copy/selection mode.")

(defun gterm-copy-mode ()
  "Toggle copy mode for selecting and copying terminal text.
In copy mode, normal Emacs movement and selection keys work.
Press `q' or `C-c C-c' to exit copy mode.
Selected text is copied to the kill ring on exit."
  (interactive)
  (if gterm--copy-mode
      (gterm--copy-mode-exit)
    (gterm--copy-mode-enter)))

(defun gterm--copy-mode-enter ()
  "Enter copy mode."
  (setq gterm--copy-mode t)
  (setq buffer-read-only t)
  (use-local-map gterm-copy-mode-map)
  (message "gterm copy mode: move and select, `q' to exit, `y' to copy & exit"))

(defun gterm--copy-mode-exit ()
  "Exit copy mode and return to terminal mode."
  (when (region-active-p)
    (kill-ring-save (region-beginning) (region-end))
    (message "Copied to kill ring"))
  (deactivate-mark)
  (setq gterm--copy-mode nil)
  (use-local-map gterm-mode-map))

(defun gterm-copy-mode-copy-and-exit ()
  "Copy selected region to kill ring and exit copy mode."
  (interactive)
  (when (region-active-p)
    (kill-ring-save (region-beginning) (region-end))
    (message "Copied to kill ring"))
  (gterm--copy-mode-exit))

(defvar gterm-copy-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Inherit standard Emacs movement keys
    (set-keymap-parent map special-mode-map)
    ;; Exit keys
    (define-key map (kbd "q") #'gterm--copy-mode-exit)
    (define-key map (kbd "C-c C-c") #'gterm--copy-mode-exit)
    ;; Copy and exit
    (define-key map (kbd "y") #'gterm-copy-mode-copy-and-exit)
    (define-key map (kbd "M-w") #'gterm-copy-mode-copy-and-exit)
    ;; Selection
    (define-key map (kbd "C-SPC") #'set-mark-command)
    (define-key map (kbd "C-@") #'set-mark-command)
    map)
  "Keymap for gterm copy mode.")

;; ── Scrollback ──────────────────────────────────────────────────────────

(defun gterm-scroll-up ()
  "Scroll the terminal viewport up into scrollback history."
  (interactive)
  (when gterm--term
    (gterm-scroll-viewport gterm--term (- (/ gterm--height 2)))
    (setq gterm--scrollback-p t)
    (gterm--full-refresh)))

(defun gterm-scroll-down ()
  "Scroll the terminal viewport down toward live output."
  (interactive)
  (when gterm--term
    (gterm-scroll-viewport gterm--term (/ gterm--height 2))
    (setq gterm--scrollback-p
          (not (gterm-viewport-is-bottom gterm--term)))
    (gterm--full-refresh)))

(defun gterm-scroll-to-bottom ()
  "Scroll the terminal viewport back to the live terminal."
  (interactive)
  (when gterm--term
    (gterm-scroll-viewport gterm--term 0)
    (setq gterm--scrollback-p nil)
    (gterm--full-refresh)))

;; ── Drag and drop ───────────────────────────────────────────────────────

(defun gterm--bracketed-paste-p ()
  "Return non-nil if the terminal has bracketed paste mode enabled."
  (and gterm--term
       (fboundp 'gterm-mode-enabled)
       (gterm-mode-enabled gterm--term 2004)))

(defun gterm--send-paste (text)
  "Send TEXT as a paste, with bracketed paste wrapping if the terminal wants it."
  (if (gterm--bracketed-paste-p)
      (gterm-send-string (concat "\033[200~" text "\033[201~"))
    (gterm-send-string text)))

(defun gterm-handle-drop (event)
  "Handle a drag-and-drop EVENT by sending the file path to the terminal.
Event format: (drag-n-drop POSITION (file OPERATIONS PATH...))."
  (interactive "e")
  (let* ((data (caddr event))           ; (file (ops...) path1 path2 ...)
         (paths (when (and (listp data) (eq (car data) 'file))
                  (cddr data))))         ; skip 'file and operations list
    (when paths
      ;; Escape spaces with backslashes (like iTerm2 does)
      (let ((text (mapconcat
                   (lambda (path)
                     (replace-regexp-in-string " " "\\\\ " path))
                   paths " ")))
        (gterm--send-paste text)))))

(defun gterm--setup-drag-drop ()
  "Set up drag-and-drop handling for the gterm buffer."
  (setq-local dnd-protocol-alist
              '(("^file:" . gterm--dnd-handler)))
  ;; Handle drag-drop event in the keymap
  (local-set-key [drag-n-drop] #'gterm-handle-drop)
  (local-set-key [C-drag-n-drop] #'gterm-handle-drop)
  (local-set-key [M-drag-n-drop] #'gterm-handle-drop))

(defun gterm--dnd-handler (uri _action)
  "Handle a DND URI drop by sending the file path to the terminal."
  (let ((file (if (string-prefix-p "file://" uri)
                  (url-unhex-string (substring uri 7))
                uri)))
    (when (and gterm--term gterm--process (process-live-p gterm--process))
      (gterm--send-paste file)))
  'private)

;; ── Window size tracking ────────────────────────────────────────────────

(defun gterm--calculate-size ()
  "Calculate terminal size from the current window."
  (let ((width (window-body-width))
        (height (window-body-height)))
    (cons width height)))

(defun gterm--maybe-resize ()
  "Resize the terminal if the window size changed."
  (when gterm--term
    (let* ((size (gterm--calculate-size))
           (new-width (car size))
           (new-height (cdr size)))
      (when (or (/= new-width gterm--width)
                (/= new-height gterm--height))
        (setq gterm--width new-width
              gterm--height new-height)
        (gterm-resize gterm--term new-width new-height)
        (when (and gterm--process (process-live-p gterm--process))
          (set-process-window-size gterm--process new-height new-width))
        (gterm--full-refresh)))))

;; ── Mode definition ─────────────────────────────────────────────────────

(defvar gterm-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Printable chars go directly to the shell
    (cl-loop for c from 32 to 126
             do (define-key map (char-to-string c) #'gterm-send-key))
    ;; Basic keys
    (define-key map (kbd "RET") #'gterm-send-return)
    (define-key map (kbd "DEL") #'gterm-send-backspace)
    (define-key map (kbd "TAB") #'gterm-send-key)
    ;; Note: ESC is not bound directly as it conflicts with Meta prefix
    ;; Ctrl keys via C-c prefix (Emacs convention for major mode)
    (define-key map (kbd "C-c C-c") #'gterm-send-ctrl-c)
    (define-key map (kbd "C-c C-d") #'gterm-send-ctrl-d)
    (define-key map (kbd "C-c C-z") #'gterm-send-ctrl-z)
    ;; Direct Ctrl keys (except C-c which is prefix, C-g which is quit)
    ;; Ctrl keys: skip C-c (prefix), C-g (quit), C-x (prefix),
    ;; C-h (help), C-m (same as RET), C-i (same as TAB)
    (cl-loop for c from ?a to ?z
             unless (memq c '(?c ?g ?h ?i ?m ?x))
             do (define-key map (vector (list 'control c)) #'gterm-send-ctrl-key))
    ;; Arrow keys
    (define-key map (kbd "<up>") #'gterm-send-up)
    (define-key map (kbd "<down>") #'gterm-send-down)
    (define-key map (kbd "<right>") #'gterm-send-right)
    (define-key map (kbd "<left>") #'gterm-send-left)
    ;; Navigation keys
    (define-key map (kbd "<home>") #'gterm-send-home)
    (define-key map (kbd "<end>") #'gterm-send-end)
    (define-key map (kbd "<deletechar>") #'gterm-send-delete)
    (define-key map (kbd "<insert>") #'gterm-send-insert)
    (define-key map (kbd "<prior>") #'gterm-send-page-up)
    (define-key map (kbd "<next>") #'gterm-send-page-down)
    ;; Function keys
    (define-key map (kbd "<f1>") #'gterm-send-f1)
    (define-key map (kbd "<f2>") #'gterm-send-f2)
    (define-key map (kbd "<f3>") #'gterm-send-f3)
    (define-key map (kbd "<f4>") #'gterm-send-f4)
    (define-key map (kbd "<f5>") #'gterm-send-f5)
    (define-key map (kbd "<f6>") #'gterm-send-f6)
    (define-key map (kbd "<f7>") #'gterm-send-f7)
    (define-key map (kbd "<f8>") #'gterm-send-f8)
    (define-key map (kbd "<f9>") #'gterm-send-f9)
    (define-key map (kbd "<f10>") #'gterm-send-f10)
    (define-key map (kbd "<f11>") #'gterm-send-f11)
    (define-key map (kbd "<f12>") #'gterm-send-f12)
    ;; Modified arrow keys
    (define-key map (kbd "S-<up>") #'gterm-send-S-up)
    (define-key map (kbd "S-<down>") #'gterm-send-S-down)
    (define-key map (kbd "S-<right>") #'gterm-send-S-right)
    (define-key map (kbd "S-<left>") #'gterm-send-S-left)
    (define-key map (kbd "C-<right>") #'gterm-send-C-right)
    (define-key map (kbd "C-<left>") #'gterm-send-C-left)
    (define-key map (kbd "M-<right>") #'gterm-send-M-right)
    (define-key map (kbd "M-<left>") #'gterm-send-M-left)
    ;; Paste from kill ring
    (define-key map (kbd "C-y") #'gterm-yank)
    (define-key map (kbd "s-v") #'gterm-yank)  ; Cmd-V on macOS
    ;; Copy mode
    (define-key map (kbd "C-c C-k") #'gterm-copy-mode)
    ;; Scrollback (Shift+PageUp/Down like most terminals)
    (define-key map (kbd "S-<prior>") #'gterm-scroll-up)
    (define-key map (kbd "S-<next>") #'gterm-scroll-down)
    (define-key map (kbd "C-c C-v") #'gterm-scroll-to-bottom)
    map)
  "Keymap for `gterm-mode'.")

(define-derived-mode gterm-mode fundamental-mode "GTerm"
  "Major mode for gterm terminal emulator."
  :group 'gterm
  (setq buffer-read-only t)
  (setq-local scroll-conservatively 101)
  (setq-local scroll-margin 0)
  (setq truncate-lines t)
  ;; Disable fringes to maximize terminal area
  (set-window-fringes nil 0 0)
  ;; Disable line numbers if enabled globally
  (when (bound-and-true-p display-line-numbers-mode)
    (display-line-numbers-mode -1))
  ;; Enable drag-and-drop file handling
  (gterm--setup-drag-drop)
  (add-hook 'window-size-change-functions
            (lambda (_frame)
              (when (derived-mode-p 'gterm-mode)
                (gterm--maybe-resize)))
            nil t)
  (add-hook 'kill-buffer-hook #'gterm--kill-buffer nil t))

(defun gterm--kill-buffer ()
  "Clean up when the gterm buffer is killed."
  (when gterm--refresh-timer
    (cancel-timer gterm--refresh-timer))
  (when (and gterm--process (process-live-p gterm--process))
    (delete-process gterm--process))
  (when gterm--term
    (gterm-free gterm--term)
    (setq gterm--term nil)))

;; ── Public interface ────────────────────────────────────────────────────

;;;###autoload
(defun gterm ()
  "Create a new gterm terminal buffer."
  (interactive)
  (let ((buf (generate-new-buffer "*gterm*")))
    (with-current-buffer buf (gterm-mode))
    ;; Display first so window dimensions are available
    (switch-to-buffer buf)
    (with-current-buffer buf
      (let* ((size (gterm--calculate-size))
             (cols (car size))
             (rows (cdr size)))
        ;; Create terminal instance
        (setq gterm--width cols
              gterm--height rows
              gterm--term (gterm-new cols rows))
        ;; Start shell process
        (let ((process-environment
               (append
                (list (format "TERM=%s" gterm-term-environment-variable)
                      (format "COLUMNS=%d" cols)
                      (format "LINES=%d" rows))
                process-environment)))
          (setq gterm--process
                (make-process
                 :name "gterm"
                 :buffer buf
                 :command (list gterm-shell "-l")
                 :coding 'no-conversion
                 :filter #'gterm--filter
                 :sentinel #'gterm--sentinel
                 :noquery t))
          (set-process-window-size gterm--process rows cols))))))

(provide 'gterm)

;;; gterm.el ends here
