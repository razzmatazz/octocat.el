;;; octocat-image-tests.el --- ERT tests for octocat-image.el  -*- lexical-binding: t; -*-

;; Assisted-by: Claude:claude-opus-5-5

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-image-tests.el
;;
;; Batch Emacs cannot display images, so `display-images-p' and the
;; image itself are stubbed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'octocat)

(ert-deftest octocat-image-test-allowed ()
  "Only GitHub's upload hosts are fetched, over https on its port."
  (dolist (url '("https://user-images.githubusercontent.com/1/a.png"
                 "https://private-user-images.githubusercontent.com/1/a.png?jwt=x"
                 "https://github.com/user-attachments/assets/83990db3-511c"
                 "https://GitHub.com/user-attachments/assets/83990db3-511c"))
    (should (octocat-image-allowed-p url)))
  (dolist (url '("http://user-images.githubusercontent.com/1/a.png"
                 "https://user-images.githubusercontent.com:8443/1/a.png"
                 "https://user-images.githubusercontent.com.evil.com/1/a.png"
                 "https://evil.com/user-images.githubusercontent.com/a.png"
                 "https://github.com/octocat/repo/raw/main/a.png"
                 "https://github-production-user-asset-6210df.s3.amazonaws.com/a.jpg"
                 "https://example.com/a.png" "" "not a url"))
    (should-not (octocat-image-allowed-p url)))
  (should (octocat-image--redirect-allowed-p
           "https://github-production-user-asset-6210df.s3.amazonaws.com/1/a.jpg?X-Amz=1"))
  (should-not (octocat-image--redirect-allowed-p "https://s3.amazonaws.com/other/a.jpg")))

(ert-deftest octocat-image-test-fill-margin ()
  "An image filling its columns, as in a table, is centred by its margin."
  ;; 19 columns of 10 pixels around an image 100 wide.
  (should (= (octocat-image--fill-margin 100 19 10) 45))
  (should (= (octocat-image--fill-margin 190 19 10) 0))
  ;; Never negative, though the image should not be wider than its columns.
  (should (= (octocat-image--fill-margin 300 19 10) 0)))

(ert-deftest octocat-image-test-fetched-redirect ()
  "A redirect is followed only to an allowed host, and only so many times."
  (let (calls result)
    (cl-letf (((symbol-function 'octocat-image--fetch)
               (lambda (url hops _cb) (push (list url hops) calls))))
      (dolist (to '("https://private-user-images.githubusercontent.com/a.png"
                    "https://example.com/a.png"))
        (with-temp-buffer
          (octocat-image--fetched `(:error (error http-redirect-limit ,to)) 2
                                  (lambda (r) (setq result (list r)))))))
    (should (equal calls '(("https://private-user-images.githubusercontent.com/a.png" 1))))
    (should (equal result '(nil)))
    (setq result nil)
    (with-temp-buffer
      (octocat-image--fetched '(:error (error http-redirect-limit
                                              "https://private-user-images.githubusercontent.com/a.png"))
                              0 (lambda (r) (setq result (list r)))))
    (should (equal result '(nil)))
    (with-temp-buffer
      (insert "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\nBYTES")
      (octocat-image--fetched nil 2 (lambda (r) (setq result r))))
    (should (equal result "BYTES"))))

(ert-deftest octocat-image-test-show-on-ret ()
  "Nothing is fetched until RET; then the image is shown, and again after a re-render."
  (let ((octocat-image--cache (make-hash-table :test #'equal))
        (octocat-image--waiting (make-hash-table :test #'equal))
        (url "https://user-images.githubusercontent.com/1/a.png")
        fetched)
    (cl-letf (((symbol-function 'display-images-p) #'always)
              ((symbol-function 'image-type-from-data) (lambda (_) 'png))
              ((symbol-function 'image-type-available-p) #'always)
              ((symbol-function 'octocat-image--image) (lambda (data _plist) (list 'img data)))
              ((symbol-function 'octocat-image--fetch)
               (lambda (u _hops cb) (push u fetched) (funcall cb "BYTES"))))
      (with-temp-buffer
        (let* ((md   (format "![a](%s)\n\n![c](https://example.com/c.png)" url))
               (draw (lambda ()
                       (erase-buffer)
                       (insert (octocat--markdown-string md "" nil 80))
                       (octocat-image--fontify (point-min) (point-max))))
               (at   (lambda (label prop)
                       (goto-char (point-min))
                       (search-forward label)
                       (get-text-property (match-beginning 0) prop))))
          (funcall draw)
          (should (memq #'octocat-image--fontify jit-lock-functions))
          (should-not fetched)
          (should-not (funcall at "[image: a]" 'display))
          (should (eq (funcall at "[image: a]" 'keymap) octocat-image-map))
          (should-not (eq (funcall at "[image: c]" 'keymap) octocat-image-map))
          (goto-char (point-min))
          (search-forward "[image: a]")
          (backward-char)
          (octocat-image-show)
          (should (equal fetched (list url)))
          (octocat-image--fontify (point-min) (point-max))
          (should (equal (funcall at "[image: a]" 'display) '(img "BYTES")))
          (should-not (funcall at "[image: a]" 'face))
          (should (eq (funcall at "[image: a]" 'keymap) octocat-markdown-link-map))
          ;; A re-render, as on `gr', draws the link again: it is shown again.
          (funcall draw)
          (should (equal (funcall at "[image: a]" 'display) '(img "BYTES")))
          (should (equal fetched (list url))))))))

(ert-deftest octocat-image-test-repo-file ()
  "A README's relative image is fetched by `octocat-image-file-function' alone."
  (let* ((asked nil)
         (octocat-image--cache (make-hash-table :test #'equal))
         (octocat-image--waiting (make-hash-table :test #'equal))
         (octocat-image-file-function
          (lambda (repo ref path cb) (push (list repo ref path) asked) (funcall cb "BYTES")))
         (octocat-markdown-base '("o/r" "main" "")))
    (cl-letf (((symbol-function 'display-images-p) #'always)
              ((symbol-function 'image-type-from-data) (lambda (_) 'png))
              ((symbol-function 'image-type-available-p) #'always)
              ((symbol-function 'octocat-image--image) (lambda (data _plist) (list 'img data)))
              ((symbol-function 'octocat-image--fetch)
               (lambda (&rest _) (error "Fetched over http"))))
      (with-temp-buffer
        (insert (octocat--markdown-string "![a](docs/a.png)" "" nil 80))
        (octocat-image--fontify (point-min) (point-max))
        (goto-char (point-min))
        (search-forward "[image: a]")
        (should (eq (get-text-property (match-beginning 0) 'keymap) octocat-image-map))
        (backward-char)
        (octocat-image-show)
        (octocat-image--fontify (point-min) (point-max))
        (should (equal asked '(("o/r" "main" "docs/a.png"))))
        (let ((pos (match-beginning 0)))
          (should (equal (get-text-property pos 'display) '(img "BYTES")))
          ;; RET opens its github.com page, which is the file viewer's.
          (should (eq (get-text-property pos 'keymap) octocat-markdown-link-map))
          (should (equal (octocat--github-url-target
                          (get-text-property pos 'octocat-markdown-url))
                         '(blob "o/r" "main" "docs" "a.png"))))))))

(ert-deftest octocat-image-test-reset ()
  "A reset shows a shown image as its link again; asking again shows it from memory."
  (let* ((octocat-image--cache (make-hash-table :test #'equal))
         (octocat-image--waiting (make-hash-table :test #'equal))
         (fetched 0)
         (octocat-image-file-function
          (lambda (_repo _ref _path cb) (cl-incf fetched) (funcall cb "BYTES")))
         (octocat-markdown-base '("o/r" "main" "")))
    (cl-letf (((symbol-function 'display-images-p) #'always)
              ((symbol-function 'image-type-from-data) (lambda (_) 'png))
              ((symbol-function 'image-type-available-p) #'always)
              ((symbol-function 'octocat-image--image) (lambda (data _plist) (list 'img data))))
      (with-temp-buffer
        (insert (octocat--markdown-string "![a](a.png)" "" nil 80))
        (goto-char (point-min))
        (search-forward "[image: a]")
        (let ((pos (match-beginning 0))
              (face (get-text-property (match-beginning 0) 'face)))
          (goto-char pos)
          (octocat-image-show)
          (octocat-image--fontify (point-min) (point-max))
          (should (equal (get-text-property pos 'display) '(img "BYTES")))
          (octocat-image-reset)
          (octocat-image--fontify (point-min) (point-max))
          (should-not (get-text-property pos 'display))
          (should (equal (get-text-property pos 'face) face))
          (should (eq (get-text-property pos 'keymap) octocat-image-map))
          (octocat-image-show)
          (octocat-image--fontify (point-min) (point-max))
          (should (equal (get-text-property pos 'display) '(img "BYTES")))
          (should (= fetched 1)))))))

(ert-deftest octocat-image-test-loading ()
  "While a requested image loads, the buffer's mode line says so."
  (let* ((done nil)
         (octocat-image--cache (make-hash-table :test #'equal))
         (octocat-image--waiting (make-hash-table :test #'equal))
         (octocat-image-file-function (lambda (_repo _ref _path cb) (setq done cb)))
         (octocat-markdown-base '("o/r" "main" "")))
    (cl-letf (((symbol-function 'display-images-p) #'always)
              ((symbol-function 'image-type-from-data) (lambda (_) 'png))
              ((symbol-function 'image-type-available-p) #'always)
              ((symbol-function 'octocat-image--image) (lambda (data _plist) (list 'img data))))
      (with-temp-buffer
        (insert (octocat--markdown-string "![a](a.png)" "" nil 80))
        (octocat-image--fontify (point-min) (point-max))
        (goto-char (point-min))
        (search-forward "[image: a]")
        (backward-char)
        (should-not mode-line-process)
        (octocat-image-show)
        ;; Asked twice, it is still one image loading.
        (octocat-image-show)
        (should (equal (car mode-line-process) ":loading "))
        (octocat-image--fontify (point-min) (point-max))
        (should (equal (substring-no-properties (get-text-property (point) 'display))
                       "… [image: a]"))
        ;; Each frame of the spinner, as `octocat-vui' turns it.
        (should (equal (substring-no-properties
                        (funcall (get-text-property (point) 'octocat-vui-spinner) "▘"))
                       "▘ [image: a]"))
        (funcall done "BYTES")
        (should-not mode-line-process)
        (octocat-image--fontify (point-min) (point-max))
        (should (equal (get-text-property (point) 'display) '(img "BYTES")))
        (should-not (get-text-property (point) 'octocat-vui-spinner))))))

(ert-deftest octocat-image-test-failed-unmarked ()
  "An image that could not be had shows its link again, not that it loads."
  (let* ((done nil)
         (octocat-image--cache (make-hash-table :test #'equal))
         (octocat-image--waiting (make-hash-table :test #'equal))
         (octocat-image-file-function (lambda (_repo _ref _path cb) (setq done cb)))
         (octocat-markdown-base '("o/r" "main" "")))
    (cl-letf (((symbol-function 'display-images-p) #'always)
              ((symbol-function 'message) #'ignore))
      (with-temp-buffer
        (insert (octocat--markdown-string "![a](a.png)" "" nil 80))
        (goto-char (point-min))
        (search-forward "[image: a]")
        (backward-char)
        (octocat-image-show)
        (octocat-image--fontify (point-min) (point-max))
        (should (get-text-property (point) 'display))
        (funcall done nil)
        (octocat-image--fontify (point-min) (point-max))
        (should-not (get-text-property (point) 'display))
        (should (eq (get-text-property (point) 'keymap) octocat-image-map))))))

(provide 'octocat-image-tests)
;;; octocat-image-tests.el ends here
