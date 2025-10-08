# org-roam-async

If your `org-roam-db-sync` is slow, try this.

1. Put the file somewhere in your `load-path` (it MUST be in `load-path`)
2. Install [el-job](https://github.com/meedstrom/el-job/)
3. Type `M-x org-roam-async-db-sync`

## A .gif

![Screencast](screencast.gif)

## Make org-roam always async

```elisp
(advice-add 'org-roam-db-autosync--try-update-on-save-h :override
            #'org-roam-async--try-update-on-save-h)
(advice-add 'org-roam-db-sync :override
            #'org-roam-async-db-sync)
```

## Check for yourself that the DB looks right

Use this command and look around:

    M-x org-roam-async-open-db
