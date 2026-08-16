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
