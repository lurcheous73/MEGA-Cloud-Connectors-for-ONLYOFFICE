/* MEGA S4 LIVE EXTENSION v1
 * CommunityServer 12.8 Files/Connected Clouds integration.
 *
 * This extension deliberately reuses ONLYOFFICE's native ThirdParty account
 * machinery. Access key -> login, secret key -> password, endpoint -> url,
 * and bucket/region/path-style/TLS metadata -> encrypted token.
 */
(function () {
    if (window.__megaS4OnlyOfficeExtensionInstalled) {
        return;
    }
    window.__megaS4OnlyOfficeExtensionInstalled = true;

    var ENDPOINT = "https://s3.g.megas4.com";
    var REGION = "g";

    function showError(message) {
        if (window.ASC && ASC.Files && ASC.Files.UI) {
            ASC.Files.UI.displayInfoPanel(message, true);
        }
    }

    function customiseMegaS4Account() {
        var account = jq("#account_MegaS4");
        if (!account.length) {
            return;
        }

        var urlRow = account.find(".account-field-url");
        urlRow.find(".account-field-title").text("Endpoint");
        var urlInput = urlRow.find(".account-input-url");
        if (!urlInput.val()) {
            urlInput.val(ENDPOINT);
        }

        var login = account.find(".account-input-login");
        login.closest(".account-field-row").find(".account-field-title").text("Access key");

        var password = account.find(".account-input-pass");
        password.closest(".account-field-row").find(".account-field-title").text("Secret key");

        if (!account.find(".account-input-megas4-bucket").length) {
            var bucketRow = jq(
                '<div class="account-field-row mega-s4-bucket-row">' +
                    '<div class="account-field-title">Bucket</div>' +
                    '<div class="account-field-body">' +
                        '<input type="text" class="textEdit account-input-megas4-bucket" name="account-field" autocomplete="off" />' +
                    '</div>' +
                '</div>'
            );
            account.find(".account-log-pass-container").append(bucketRow);
        }
    }

    function installMegaS4() {
        if (!window.ASC || !ASC.Files || !ASC.Files.ThirdParty || !window.jq) {
            return;
        }

        var thirdParty = ASC.Files.ThirdParty;

        thirdParty.thirdPartyList.MegaS4 = {
            key: "MegaS4",
            customerTitle: "MEGA S4",
            providerTitle: "MEGA S4",
            urlRequest: true
        };

        if (!thirdParty.__megaS4OriginalAddNewThirdPartyAccount) {
            thirdParty.__megaS4OriginalAddNewThirdPartyAccount = thirdParty.addNewThirdPartyAccount;
            thirdParty.addNewThirdPartyAccount = function (provider) {
                var result = thirdParty.__megaS4OriginalAddNewThirdPartyAccount.apply(this, arguments);
                if (provider && provider.key === "MegaS4") {
                    customiseMegaS4Account();
                }
                return result;
            };
        }

        if (!thirdParty.__megaS4OriginalSaveThirdPartyAccount) {
            thirdParty.__megaS4OriginalSaveThirdPartyAccount = thirdParty.saveThirdPartyAccount;
            thirdParty.saveThirdPartyAccount = function (obj) {
                var account = jq(obj).parents(".account-row");
                var providerKey = (account.find(".account-hidden-provider-key").val() || "").trim();

                if (providerKey !== "MegaS4") {
                    return thirdParty.__megaS4OriginalSaveThirdPartyAccount.apply(this, arguments);
                }

                var providerId = parseInt(account.find(".account-hidden-provider-id").val(), 10);
                if (providerId) {
                    showError("MEGA S4 credentials are not edited in place in this first release. Delete the connection and reconnect it with the new credentials.");
                    return false;
                }

                var customerTitle = (account.find(".account-input-folder").val() || "").trim();
                var connectUrl = (account.find(".account-input-url").val() || "").trim() || ENDPOINT;
                var login = (account.find(".account-input-login").val() || "").trim();
                var password = (account.find(".account-input-pass").val() || "").trim();
                var bucket = (account.find(".account-input-megas4-bucket").val() || "").trim();
                var corporate = account.find(".account-cbx-corporate").prop("checked") === true;

                if (!customerTitle || !connectUrl || !login || !password || !bucket) {
                    showError("Folder title, endpoint, access key, secret key and bucket are required for MEGA S4.");
                    return false;
                }

                /* MegaS4Auth v1: version, bucket, region, force-path-style, use-http. */
                var token = window.btoa("1\n" + bucket + "\n" + REGION + "\n1\n0");

                account.find("input").prop("disabled", true);
                account.find("a.button.account-save-link").addClass("disable");

                var params = {
                    providerId: null,
                    providerKey: "MegaS4",
                    folderTitle: customerTitle,
                    login: login,
                    password: password,
                    token: token,
                    corporate: corporate
                };

                var data = {
                    third_party: {
                        auth_data: {
                            login: login,
                            password: password,
                            token: token,
                            url: connectUrl
                        },
                        corporate: corporate,
                        customer_title: customerTitle,
                        provider_id: null,
                        provider_key: "MegaS4"
                    }
                };

                ASC.Files.ServiceManager.saveThirdParty(
                    ASC.Files.ServiceManager.events.SaveThirdParty,
                    params,
                    data
                );
                return false;
            };
        }

        var host = jq("#thirdPartyNewAccount .clearFix").first();
        if (host.length && !host.find(".add-account-button.MegaS4").length) {
            var tile = jq(
                '<span class="add-account-big add-account-button WebDav MegaS4" ' +
                'data-provider="MegaS4" title="MEGA S4">MEGA S4</span>'
            );
            host.append(tile);
            tile.on("click", ASC.Files.ThirdParty.addAccountButton);
        }
    }

    if (window.jq) {
        jq(function () {
            installMegaS4();
        });
    }
})();


/* MEGA S4 LIVE EXTENSION v2
 * CommunityServer 12.8 Files/Connected Clouds integration.
 *
 * v2 deliberately does not trust page-load timing. It retries until ONLYOFFICE's
 * jq alias, ASC.Files.ThirdParty object and popup DOM are all present, and it
 * re-ensures the MEGA S4 tile immediately before the stock popup opens.
 *
 * Access key -> login, secret key -> password, endpoint -> url, and
 * bucket/region/path-style/TLS metadata -> encrypted token.
 */
(function () {
    if (window.__megaS4OnlyOfficeExtensionV2Loaded) {
        return;
    }
    window.__megaS4OnlyOfficeExtensionV2Loaded = true;

    var ENDPOINT = "https://s3.g.megas4.com";
    var REGION = "g";
    var MAX_ATTEMPTS = 120;
    var attempts = 0;
    var timer = null;

    function showError(message) {
        if (window.ASC && ASC.Files && ASC.Files.UI) {
            ASC.Files.UI.displayInfoPanel(message, true);
        }
    }

    function prerequisitesReady() {
        return !!(
            window.jq &&
            window.ASC &&
            ASC.Files &&
            ASC.Files.ThirdParty &&
            ASC.Files.ThirdParty.thirdPartyList &&
            document.getElementById("thirdPartyNewAccount")
        );
    }

    function customiseMegaS4Account() {
        var account = jq("#account_MegaS4");
        if (!account.length) {
            return;
        }

        var urlRow = account.find(".account-field-url");
        urlRow.find(".account-field-title").text("Endpoint");
        var urlInput = urlRow.find(".account-input-url");
        if (!urlInput.val()) {
            urlInput.val(ENDPOINT);
        }

        var login = account.find(".account-input-login");
        login.closest(".account-field-row").find(".account-field-title").text("Access key");

        var password = account.find(".account-input-pass");
        password.closest(".account-field-row").find(".account-field-title").text("Secret key");

        if (!account.find(".account-input-megas4-bucket").length) {
            var bucketRow = jq(
                '<div class="account-field-row mega-s4-bucket-row">' +
                    '<div class="account-field-title">Bucket</div>' +
                    '<div class="account-field-body">' +
                        '<input type="text" class="textEdit account-input-megas4-bucket" name="account-field" autocomplete="off" />' +
                    '</div>' +
                '</div>'
            );
            account.find(".account-log-pass-container").append(bucketRow);
        }
    }

    function ensureTile(thirdParty) {
        var host = jq("#thirdPartyNewAccount .clearFix").first();
        if (!host.length) {
            return false;
        }

        var existing = host.find('.add-account-button[data-provider="MegaS4"]');
        if (existing.length) {
            return true;
        }

        var tile = jq(
            '<span class="add-account-big add-account-button WebDav MegaS4" ' +
            'data-provider="MegaS4" title="MEGA S4">MEGA S4</span>'
        );

        host.append(tile);
        tile.on("click", thirdParty.addAccountButton);
        return true;
    }

    function installMegaS4() {
        attempts += 1;

        if (!prerequisitesReady()) {
            return false;
        }

        var thirdParty = ASC.Files.ThirdParty;

        thirdParty.thirdPartyList.MegaS4 = {
            key: "MegaS4",
            customerTitle: "MEGA S4",
            providerTitle: "MEGA S4",
            urlRequest: true
        };

        if (!thirdParty.__megaS4V2OriginalAddNewThirdPartyAccount) {
            thirdParty.__megaS4V2OriginalAddNewThirdPartyAccount = thirdParty.addNewThirdPartyAccount;
            thirdParty.addNewThirdPartyAccount = function (provider) {
                var result = thirdParty.__megaS4V2OriginalAddNewThirdPartyAccount.apply(this, arguments);
                if (provider && provider.key === "MegaS4") {
                    customiseMegaS4Account();
                }
                return result;
            };
        }

        if (!thirdParty.__megaS4V2OriginalSaveThirdPartyAccount) {
            thirdParty.__megaS4V2OriginalSaveThirdPartyAccount = thirdParty.saveThirdPartyAccount;
            thirdParty.saveThirdPartyAccount = function (obj) {
                var account = jq(obj).parents(".account-row");
                var providerKey = (account.find(".account-hidden-provider-key").val() || "").trim();

                if (providerKey !== "MegaS4") {
                    return thirdParty.__megaS4V2OriginalSaveThirdPartyAccount.apply(this, arguments);
                }

                var providerId = parseInt(account.find(".account-hidden-provider-id").val(), 10);
                if (providerId) {
                    showError("MEGA S4 credentials are not edited in place in this first release. Delete the connection and reconnect it with the new credentials.");
                    return false;
                }

                var customerTitle = (account.find(".account-input-folder").val() || "").trim();
                var connectUrl = (account.find(".account-input-url").val() || "").trim() || ENDPOINT;
                var login = (account.find(".account-input-login").val() || "").trim();
                var password = (account.find(".account-input-pass").val() || "").trim();
                var bucket = (account.find(".account-input-megas4-bucket").val() || "").trim();
                var corporate = account.find(".account-cbx-corporate").prop("checked") === true;

                if (!customerTitle || !connectUrl || !login || !password || !bucket) {
                    showError("Folder title, endpoint, access key, secret key and bucket are required for MEGA S4.");
                    return false;
                }

                /* MegaS4Auth v1: version, bucket, region, force-path-style, use-http. */
                var token = window.btoa("1\n" + bucket + "\n" + REGION + "\n1\n0");

                account.find("input").prop("disabled", true);
                account.find("a.button.account-save-link").addClass("disable");

                var params = {
                    providerId: null,
                    providerKey: "MegaS4",
                    folderTitle: customerTitle,
                    login: login,
                    password: password,
                    token: token,
                    corporate: corporate
                };

                var data = {
                    third_party: {
                        auth_data: {
                            login: login,
                            password: password,
                            token: token,
                            url: connectUrl
                        },
                        corporate: corporate,
                        customer_title: customerTitle,
                        provider_id: null,
                        provider_key: "MegaS4"
                    }
                };

                ASC.Files.ServiceManager.saveThirdParty(
                    ASC.Files.ServiceManager.events.SaveThirdParty,
                    params,
                    data
                );
                return false;
            };
        }

        if (!thirdParty.__megaS4V2OriginalShowThirdPartyNewAccount) {
            thirdParty.__megaS4V2OriginalShowThirdPartyNewAccount = thirdParty.showThirdPartyNewAccount;
            thirdParty.showThirdPartyNewAccount = function () {
                ensureTile(thirdParty);
                return thirdParty.__megaS4V2OriginalShowThirdPartyNewAccount.apply(this, arguments);
            };
        }

        ensureTile(thirdParty);
        thirdParty.__megaS4V2Installed = true;
        window.__megaS4OnlyOfficeExtensionInstalled = true;
        return true;
    }

    function schedule(delay) {
        if (timer || attempts >= MAX_ATTEMPTS) {
            return;
        }
        timer = window.setTimeout(function () {
            timer = null;
            if (!installMegaS4() && attempts < MAX_ATTEMPTS) {
                schedule(250);
            }
        }, delay);
    }

    schedule(0);

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", function () { schedule(0); }, { once: true });
    }
    window.addEventListener("load", function () { schedule(0); }, { once: true });
})();


/* MEGA S4 LIVE EXTENSION v3 — deterministic credential-field layout.
 * This overlay deliberately runs after v2 so it can be appended safely to an
 * already-patched CommunityServer bundle without replacing v2's save plumbing.
 */
(function () {
    if (window.__megaS4OnlyOfficeExtensionV3Loaded) {
        return;
    }
    window.__megaS4OnlyOfficeExtensionV3Loaded = true;

    var attempts = 0;
    var MAX_ATTEMPTS = 120;
    var timer = null;
    var observer = null;

    function normaliseMegaS4Form() {
        if (!window.jq) {
            return false;
        }

        var account = jq("#account_MegaS4");
        if (!account.length) {
            return false;
        }

        var credentials = account.find(".account-log-pass-container");
        var urlRow = account.find(".account-field-url");
        var login = account.find(".account-input-login");
        var password = account.find(".account-input-pass");
        var loginRow = login.closest(".account-field-row");
        var passwordRow = password.closest(".account-field-row");

        urlRow.find(".account-field-title").text("Endpoint");
        loginRow.find(".account-field-title").text("Access key");
        passwordRow.find(".account-field-title").text("Secret key");

        login
            .removeAttr("maxlength")
            .attr("autocomplete", "off")
            .attr("autocapitalize", "none")
            .attr("spellcheck", "false");

        password
            .removeAttr("maxlength")
            .attr("type", "password")
            .attr("autocomplete", "new-password")
            .attr("autocapitalize", "none")
            .attr("spellcheck", "false");

        var bucketRow = account.find(".mega-s4-bucket-row");
        if (!bucketRow.length) {
            bucketRow = jq(
                '<div class="account-field-row mega-s4-bucket-row">' +
                    '<div class="account-field-title">Bucket name</div>' +
                    '<div class="account-field-body">' +
                        '<input type="text" class="textEdit account-input-megas4-bucket" name="account-field" autocomplete="off" autocapitalize="none" spellcheck="false" />' +
                    '</div>' +
                '</div>'
            );
        }

        bucketRow.find(".account-field-title").text("Bucket name");
        bucketRow.find(".account-input-megas4-bucket")
            .removeAttr("maxlength")
            .attr("autocomplete", "off")
            .attr("autocapitalize", "none")
            .attr("spellcheck", "false");

        /* Force the exact order requested, regardless of stock template order. */
        credentials.append(loginRow);
        credentials.append(passwordRow);
        credentials.append(bucketRow);

        account.attr("data-megas4-layout", "v3");
        return true;
    }

    function install() {
        attempts += 1;
        if (!(window.jq && window.ASC && ASC.Files && ASC.Files.ThirdParty)) {
            return false;
        }

        var thirdParty = ASC.Files.ThirdParty;

        if (!thirdParty.__megaS4V3OriginalAddNewThirdPartyAccount) {
            thirdParty.__megaS4V3OriginalAddNewThirdPartyAccount = thirdParty.addNewThirdPartyAccount;
            thirdParty.addNewThirdPartyAccount = function () {
                var result = thirdParty.__megaS4V3OriginalAddNewThirdPartyAccount.apply(this, arguments);
                normaliseMegaS4Form();
                window.setTimeout(normaliseMegaS4Form, 0);
                return result;
            };
        }

        /*
         * BRIMSTONE HOTFIX — legacy v3 MutationObserver disabled.
         *
         * v3 normaliseMegaS4Form() re-appends existing credential rows.
         * Observing childList/subtree therefore feeds those DOM mutations
         * straight back into v3.  v4.1 owns guarded mutation normalisation.
         */

        normaliseMegaS4Form();
        thirdParty.__megaS4V3Installed = true;
        return true;
    }

    function schedule(delay) {
        if (timer || attempts >= MAX_ATTEMPTS) {
            return;
        }
        timer = window.setTimeout(function () {
            timer = null;
            if (!install() && attempts < MAX_ATTEMPTS) {
                schedule(250);
            }
        }, delay);
    }

    schedule(0);
})();

/* BRIMSTONE MEGA S4 LIVE EXTENSION v4.1
 * Fixes the v4 MutationObserver feedback loop while retaining deterministic
 * credential ordering, one-time S3Compatible import, and bucket discovery.
 * BRIMSTONE CUSTOM CODE.
 */
(function () {
    if (window.__brimstoneMegaS4V41Loaded) return;
    window.__brimstoneMegaS4V41Loaded = true;

    var HANDLER = "/Products/Files/HttpHandlers/brimstone-megas4.ashx";
    var SENTINEL = "BRIMSTONE:S3COMPATIBLE:IMPORT";
    var ENDPOINT = "https://s3.g.megas4.com";
    var REGION = "g";
    var MAX_ATTEMPTS = 120;
    var attempts = 0;
    var timer = null;
    var observer = null;
    var observerTimer = null;
    var normalising = false;

    function info(message, error) {
        if (window.ASC && ASC.Files && ASC.Files.UI) {
            ASC.Files.UI.displayInfoPanel(message, error === true);
        }
    }

    function getAccount() {
        return window.jq ? jq("#account_MegaS4") : null;
    }

    function setTextIfNeeded(element, value) {
        if (element.length && element.text() !== value) element.text(value);
    }

    function ensureSharedRow(account) {
        var row = account.find(".brimstone-megas4-shared-row");
        if (row.length) return row;
        return jq(
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
    }

    function ensureBucketControls(account) {
        var row = account.find(".brimstone-megas4-bucket-actions");
        if (row.length) return row;
        return jq(
            '<div class="account-field-row brimstone-megas4-bucket-actions">' +
                '<div class="account-field-title">Buckets</div>' +
                '<div class="account-field-body">' +
                    '<a class="button middle gray brimstone-megas4-pull-buckets">Pull buckets</a>' +
                    '<span class="brimstone-megas4-bucket-status" style="margin-left:8px"></span>' +
                '</div>' +
            '</div>'
        );
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
            if (value === "__manual__") input.val("").focus();
            else if (value) input.val(value);
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
            timeout: 20000,
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
        }).fail(function (xhr, textStatus) {
            var result = xhr.responseJSON;
            var message = result && result.error ? result.error : (textStatus === "timeout" ? "MEGA S4 bucket listing timed out." : "MEGA S4 bucket listing failed.");
            info(message + " You can still enter the bucket name manually.", true);
            status.text("Failed — manual entry still available");
        }).always(function () {
            button.removeClass("disable");
        });
    }

    function rowsAlreadyOrdered(container, rows) {
        var children = container.children().toArray();
        var previous = -1;
        for (var i = 0; i < rows.length; i += 1) {
            if (!rows[i] || !rows[i].length) return false;
            var position = children.indexOf(rows[i][0]);
            if (position < 0 || (previous >= 0 && position !== previous + 1)) return false;
            previous = position;
        }
        return true;
    }

    function normaliseForm() {
        if (!window.jq || normalising) return false;
        var account = getAccount();
        if (!account || !account.length) return false;
        normalising = true;
        try {
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
            setTextIfNeeded(urlRow.find(".account-field-title"), "Endpoint");
            if (!urlRow.find(".account-input-url").val()) urlRow.find(".account-input-url").val(ENDPOINT);
            setTextIfNeeded(loginRow.find(".account-field-title"), "Access key");
            setTextIfNeeded(passwordRow.find(".account-field-title"), "Secret key");
            setTextIfNeeded(bucketRow.find(".account-field-title"), "Bucket name");
            login.removeAttr("maxlength").attr({ autocomplete: "off", autocapitalize: "none", spellcheck: "false" });
            password.removeAttr("maxlength").attr({ type: "password", autocomplete: "new-password", autocapitalize: "none", spellcheck: "false" });
            bucketRow.find(".account-input-megas4-bucket").removeAttr("maxlength").attr({ autocomplete: "off", autocapitalize: "none", spellcheck: "false" });

            var orderedRows = [urlRow, sharedRow, loginRow, passwordRow, bucketActions, bucketRow];
            if (!rowsAlreadyOrdered(credentials, orderedRows)) {
                orderedRows.forEach(function (row) { credentials.append(row); });
            }

            sharedRow.find(".brimstone-megas4-import-shared")
                .off("change.brimstone")
                .on("change.brimstone", function () { setSharedMode(account, this.checked); });
            bucketActions.find(".brimstone-megas4-pull-buckets")
                .off("click.brimstone")
                .on("click.brimstone", function (e) {
                    e.preventDefault();
                    if (!jq(this).hasClass("disable")) pullBuckets(account);
                });
            account.attr("data-brimstone-megas4-layout", "v4.1");
            return true;
        } finally {
            normalising = false;
        }
    }

    function queueNormalise() {
        if (observerTimer) return;
        observerTimer = window.setTimeout(function () {
            observerTimer = null;
            var account = getAccount();
            if (account && account.length && account.attr("data-brimstone-megas4-layout") !== "v4.1") {
                normaliseForm();
            }
        }, 0);
    }

    function install() {
        attempts += 1;
        if (!(window.jq && window.ASC && ASC.Files && ASC.Files.ThirdParty && ASC.Files.ThirdParty.__megaS4V2Installed)) return false;
        var thirdParty = ASC.Files.ThirdParty;
        if (!thirdParty.__brimstoneMegaS4V41OriginalAddNewThirdPartyAccount) {
            thirdParty.__brimstoneMegaS4V41OriginalAddNewThirdPartyAccount = thirdParty.addNewThirdPartyAccount;
            thirdParty.addNewThirdPartyAccount = function () {
                var result = thirdParty.__brimstoneMegaS4V41OriginalAddNewThirdPartyAccount.apply(this, arguments);
                normaliseForm();
                window.setTimeout(normaliseForm, 0);
                return result;
            };
        }
        if (!thirdParty.__brimstoneMegaS4V41OriginalSaveThirdPartyAccount) {
            thirdParty.__brimstoneMegaS4V41OriginalSaveThirdPartyAccount = thirdParty.saveThirdPartyAccount;
            thirdParty.saveThirdPartyAccount = function (obj) {
                var account = jq(obj).parents(".account-row");
                var providerKey = (account.find(".account-hidden-provider-key").val() || "").trim();
                if (providerKey !== "MegaS4") return thirdParty.__brimstoneMegaS4V41OriginalSaveThirdPartyAccount.apply(this, arguments);
                if (account.find(".brimstone-megas4-import-shared").prop("checked") === true) {
                    account.find(".account-input-login").prop("disabled", false).val(SENTINEL);
                    account.find(".account-input-pass").prop("disabled", false).val(SENTINEL);
                }
                return thirdParty.__brimstoneMegaS4V41OriginalSaveThirdPartyAccount.apply(this, arguments);
            };
        }
        if (!observer && window.MutationObserver) {
            var target = document.getElementById("thirdPartyAccountList") || document.body;
            observer = new MutationObserver(queueNormalise);
            observer.observe(target, { childList: true, subtree: true });
        }
        normaliseForm();
        thirdParty.__brimstoneMegaS4V41Installed = true;
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
