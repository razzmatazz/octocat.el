;;; octocat-image-tests.el --- ERT tests for octocat-image.el  -*- lexical-binding: t; -*-

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

(ert-deftest octocat-image-test-display ()
  "Fetched images are shown at once; others are requested, then put in place."
  (let ((octocat-image--cache (make-hash-table :test #'equal))
        (octocat-image--waiting (make-hash-table :test #'equal))
        (octocat-image-show t)
        (old "https://user-images.githubusercontent.com/1/old.png")
        (new "https://user-images.githubusercontent.com/1/new.png")
        requested)
    (puthash old "OLD" octocat-image--cache)
    (cl-letf (((symbol-function 'display-images-p) #'always)
              ((symbol-function 'image-type-from-data) (lambda (_) 'png))
              ((symbol-function 'image-type-available-p) #'always)
              ((symbol-function 'octocat-image--image) (lambda (data _plist) (list 'img data)))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat _fn url &rest _) (push url requested))))
      (with-temp-buffer
        (insert (octocat-image-display
                 (octocat-markdown-render
                  (format "![a](%s)\n\n![b](%s)\n\n![c](https://example.com/c.png)" old new)
                  "" 80)))
        (let ((at (lambda (label) (get-text-property
                                   (save-excursion (goto-char (point-min))
                                                   (search-forward label)
                                                   (match-beginning 0))
                                   'display))))
          (should (equal (funcall at "[image: a]") '(img "OLD")))
          (should-not (funcall at "[image: b]"))
          (should (equal requested (list new)))
          (octocat-image--arrived new "NEW")
          (should (equal (funcall at "[image: b]") '(img "NEW")))
          (should-not (funcall at "[image: c]")))))))

(provide 'octocat-image-tests)
;;; octocat-image-tests.el ends here
