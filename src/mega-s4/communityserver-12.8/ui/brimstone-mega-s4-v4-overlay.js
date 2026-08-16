/* BRIMSTONE MEGA S4 LIVE EXTENSION v4
 * Adds deterministic credential ordering, one-time import from the existing
 * S3Compatible AuthorizationKeys consumer, and server-side bucket discovery.
 * The saved shared secret is never returned to JavaScript.
 */
(function () {
    if (window.__brimstoneMegaS4V4Loaded) return;
    window.__brimstoneMegaS4V4Loaded = true;

    var HANDLER = "/Products/Files/HttpHandlers/brimstone-megas4.ashx";
    var SENTINEL = "BRIMSTONE:S3COMPATIBLE:IMPORT";
    var ENDPOINT = "https://s3.g.megas4.com";
    var REGION = "g";
    var MAX_ATTEMPTS = 120;
    var attempts = 0;
    var timer = null;
    var observer = null;

    function info(message, error) {
        if (window.ASC && ASC.Files && ASC.Files.UI) {
            ASC.Files.UI.displayInfoPanel(message, error === true);
        }
    }

    function getAccount() {
        return window.jq ? jq("#account_MegaS4") : jq();
    }

    function ensureSharedRow(account) {
        var row = account.find(".brimstone-megas4-shared-row");
        if (row.length) return row;

        row = jq(
            '<div class="account-field-row brimstone-megas4-shared-row">' +
                '<div class="account-field-title">Credentials</div>' +
                '<div class="account-field-body">' +
                    '<label>' +
                        '<input type="checkbox" class="checkbox brimstone-megas4-import-shared" /> ' +
                        'Import existing S3-Compatible backup credentials' +
                    '</label>' +
                '</div>' +
            '</div>'
        );
        return row;
    }

    function ensureBucketControls(account) {
        var row = account.find(".brimstone-megas4-bucket-actions");
        if (row.length) return row;

        row = jq(
            '<div class="account-field-row brimstone-megas4-bucket-actions">' +
                '<div class="account-field-title">Buckets</div>' +
                '<div class="account-field-body">' +
                    '<a class="button middle gray brimstone-megas4-pull-buckets">Pull buckets</a>' +
                    '<span class="brimstone-megas4-bucket-status" style="margin-left:8px"></span>' +
                '</div>' +
            '</div>'
        );
        return row;
    }

    function ensureBucketSelect(bucketRow) {
        var body = bucketRow.find(".account-field-body");
        var select = body.find(".brimstone-megas4-bucket-select");
        if (select.length) return select;

        select = jq('<select class="comboBox brimstone-megas4-bucket-select" style="display:none;margin-bottom:6px"></select>');
        body.prepend(select);
        return select;
    }

    function setSharedMode(account, enabled) {
        var login = account.find(".account-input-login");
        var password = account.find(".account-input-pass");

        if (enabled) {
            if (login.data("brimstoneManualValue") === undefined) login.data("brimstoneManualValue", login.val());
            if (password.data("brimstoneManualValue") === undefined) password.data("brimstoneManualValue", password.val());

            login.val("").prop("disabled", true).attr("placeholder", "Imported server-side on Save");
            password.val("").prop("disabled", true).attr("placeholder", "Imported server-side on Save");
        } else {
            login.prop("disabled", false).attr("placeholder", "");
            password.prop("disabled", false).attr("placeholder", "");

            if (login.data("brimstoneManualValue") !== undefined) {
                login.val(login.data("brimstoneManualValue"));
                login.removeData("brimstoneManualValue");
            }
            if (password.data("brimstoneManualValue") !== undefined) {
                password.val(password.data("brimstoneManualValue"));
                password.removeData("brimstoneManualValue");
            }
        }
    }

    function populateBuckets(account, buckets) {
        var bucketRow = account.find(".mega-s4-bucket-row");
        var input = bucketRow.find(".account-input-megas4-bucket");
        var select = ensureBucketSelect(bucketRow);
        var current = (input.val() || "").trim();

        select.empty();
        select.append(jq('<option value="">Select a bucket</option>'));
        buckets.forEach(function (name) {
            select.append(jq("<option></option>").attr("value", name).text(name));
        });
        select.append(jq('<option value="__manual__">Enter bucket name manually</option>'));
        select.show();

        if (current && buckets.indexOf(current) >= 0) {
            select.val(current);
        } else if (buckets.length === 1) {
            select.val(buckets[0]);
            input.val(buckets[0]);
        }

        select.off("change.brimstone").on("change.brimstone", function () {
            var value = jq(this).val();
            if (value === "__manual__") {
                input.val("").focus();
            } else if (value) {
                input.val(value);
            }
        });
    }

    function pullBuckets(account) {
        var useShared = account.find(".brimstone-megas4-import-shared").prop("checked") === true;
        var accessKey = (account.find(".account-input-login").val() || "").trim();
        var secretKey = account.find(".account-input-pass").val() || "";
        var endpoint = (account.find(".account-input-url").val() || ENDPOINT).trim();
        var status = account.find(".brimstone-megas4-bucket-status");
        var button = account.find(".brimstone-megas4-pull-buckets");

        if (!useShared && (!accessKey || !secretKey)) {
            info("Enter the access key and secret key first, or tick Import existing S3-Compatible backup credentials.", true);
            return;
        }

        button.addClass("disable");
        status.text("Checking…");

        jq.ajax({
            url: HANDLER,
            type: "POST",
            dataType: "json",
            data: {
                action: "list-buckets",
                source: useShared ? "shared" : "manual",
                accessKey: useShared ? "" : accessKey,
                secretKey: useShared ? "" : secretKey,
                endpoint: endpoint,
                region: REGION
            }
        }).done(function (result) {
            if (!result || result.ok !== true) {
                info((result && result.error) || "MEGA S4 bucket listing failed.", true);
                status.text("Failed — manual entry still available");
                return;
            }

            var buckets = result.buckets || [];
            populateBuckets(account, buckets);
            status.text(buckets.length ? (buckets.length + " bucket(s) found") : "No buckets returned — enter manually");
        }).fail(function (xhr) {
            var result = xhr.responseJSON;
            var message = result && result.error ? result.error : "MEGA S4 bucket listing failed.";
            info(message + " You can still enter the bucket name manually.", true);
            status.text("Failed — manual entry still available");
        }).always(function () {
            button.removeClass("disable");
        });
    }

    function normaliseForm() {
        if (!window.jq) return false;
        var account = getAccount();
        if (!account.length) return false;

        var credentials = account.find(".account-log-pass-container");
        var urlRow = account.find(".account-field-url");
        var login = account.find(".account-input-login");
        var password = account.find(".account-input-pass");
        var loginRow = login.closest(".account-field-row");
        var passwordRow = password.closest(".account-field-row");
        var bucketRow = account.find(".mega-s4-bucket-row");

        if (!bucketRow.length) {
            bucketRow = jq(
                '<div class="account-field-row mega-s4-bucket-row">' +
                    '<div class="account-field-title">Bucket name</div>' +
                    '<div class="account-field-body">' +
                        '<input type="text" class="textEdit account-input-megas4-bucket" name="account-field" autocomplete="off" />' +
                    '</div>' +
                '</div>'
            );
        }

        var sharedRow = ensureSharedRow(account);
        var bucketActions = ensureBucketControls(account);

        urlRow.find(".account-field-title").text("Endpoint");
        if (!urlRow.find(".account-input-url").val()) urlRow.find(".account-input-url").val(ENDPOINT);
        loginRow.find(".account-field-title").text("Access key");
        passwordRow.find(".account-field-title").text("Secret key");
        bucketRow.find(".account-field-title").text("Bucket name");

        login.removeAttr("maxlength").attr({ autocomplete: "off", autocapitalize: "none", spellcheck: "false" });
        password.removeAttr("maxlength").attr({ type: "password", autocomplete: "new-password", autocapitalize: "none", spellcheck: "false" });
        bucketRow.find(".account-input-megas4-bucket").removeAttr("maxlength").attr({ autocomplete: "off", autocapitalize: "none", spellcheck: "false" });

        /* Exact BRIMSTONE order: Endpoint, import, access, secret, pull, bucket. */
        credentials.append(urlRow);
        credentials.append(sharedRow);
        credentials.append(loginRow);
        credentials.append(passwordRow);
        credentials.append(bucketActions);
        credentials.append(bucketRow);

        sharedRow.find(".brimstone-megas4-import-shared")
            .off("change.brimstone")
            .on("change.brimstone", function () { setSharedMode(account, this.checked); });

        bucketActions.find(".brimstone-megas4-pull-buckets")
            .off("click.brimstone")
            .on("click.brimstone", function (e) {
                e.preventDefault();
                if (!jq(this).hasClass("disable")) pullBuckets(account);
            });

        account.attr("data-brimstone-megas4-layout", "v4");
        return true;
    }

    function install() {
        attempts += 1;
        if (!(window.jq && window.ASC && ASC.Files && ASC.Files.ThirdParty && ASC.Files.ThirdParty.__megaS4V2Installed)) {
            return false;
        }

        var thirdParty = ASC.Files.ThirdParty;

        if (!thirdParty.__brimstoneMegaS4V4OriginalAddNewThirdPartyAccount) {
            thirdParty.__brimstoneMegaS4V4OriginalAddNewThirdPartyAccount = thirdParty.addNewThirdPartyAccount;
            thirdParty.addNewThirdPartyAccount = function () {
                var result = thirdParty.__brimstoneMegaS4V4OriginalAddNewThirdPartyAccount.apply(this, arguments);
                normaliseForm();
                window.setTimeout(normaliseForm, 0);
                return result;
            };
        }

        if (!thirdParty.__brimstoneMegaS4V4OriginalSaveThirdPartyAccount) {
            thirdParty.__brimstoneMegaS4V4OriginalSaveThirdPartyAccount = thirdParty.saveThirdPartyAccount;
            thirdParty.saveThirdPartyAccount = function (obj) {
                var account = jq(obj).parents(".account-row");
                var providerKey = (account.find(".account-hidden-provider-key").val() || "").trim();
                if (providerKey !== "MegaS4") {
                    return thirdParty.__brimstoneMegaS4V4OriginalSaveThirdPartyAccount.apply(this, arguments);
                }

                if (account.find(".brimstone-megas4-import-shared").prop("checked") === true) {
                    account.find(".account-input-login").prop("disabled", false).val(SENTINEL);
                    account.find(".account-input-pass").prop("disabled", false).val(SENTINEL);
                }

                return thirdParty.__brimstoneMegaS4V4OriginalSaveThirdPartyAccount.apply(this, arguments);
            };
        }

        if (!observer && window.MutationObserver) {
            var target = document.getElementById("thirdPartyAccountList") || document.body;
            observer = new MutationObserver(function () { normaliseForm(); });
            observer.observe(target, { childList: true, subtree: true });
        }

        normaliseForm();
        thirdParty.__brimstoneMegaS4V4Installed = true;
        return true;
    }

    function schedule(delay) {
        if (timer || attempts >= MAX_ATTEMPTS) return;
        timer = window.setTimeout(function () {
            timer = null;
            if (!install() && attempts < MAX_ATTEMPTS) schedule(250);
        }, delay);
    }

    schedule(0);
})();
