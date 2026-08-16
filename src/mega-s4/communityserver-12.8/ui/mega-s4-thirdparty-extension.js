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
