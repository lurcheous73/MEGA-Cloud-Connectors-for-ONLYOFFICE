<%@ WebHandler Language="C#" Class="BrimstoneMegaS4Canary" %>

using System.Web;

// BRIMSTONE CUSTOM CODE — disposable inline ASHX canary.
public sealed class BrimstoneMegaS4Canary : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    public void ProcessRequest(HttpContext context)
    {
        context.Response.ContentType = "application/json";
        context.Response.StatusCode = 200;
        context.Response.Write("{\"ok\":true,\"brimstone\":\"ashx-canary\"}");
    }
}
