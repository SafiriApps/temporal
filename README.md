# Temporal 

This is a template for running a production-ready Temporal cluster on Render. The setup supports independent autoscaling for each Temporal service (frontend, matching, history, worker), has [visibility](https://docs.temporal.io/visibility) backed by Elasticsearch, and includes an example Go app to trigger and run workflows. Create a new repo using this template, and then click the button below to try it out:

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/render-examples/temporal)

For deploy instructions, see our [Temporal guide](https://render.com/docs/deploy-temporal).

# Signing in to the Temporal UI

The `temporal-ui` service runs [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) in front of Temporal UI, which listens only on localhost inside the container. Every page and API call requires signing in with a Google account from your Workspace domain. Sign-ins last a year.

One-time setup:

1. In the [Google Cloud Console](https://console.cloud.google.com/), signed in with a company account, create a project with **Location** set to your Workspace organization. Then, under **Google Auth Platform**:
   - **Audience**: set the user type to **Internal**.
   - **Clients** → **Create client** → **Web application**, with the authorized redirect URI `https://<temporal-ui host>/oauth2/callback`.
2. In the Render Dashboard, add these env vars to `temporal-ui` *before* deploying:
   - `OAUTH2_PROXY_CLIENT_ID` and `OAUTH2_PROXY_CLIENT_SECRET`: from step 1
   - `OAUTH2_PROXY_COOKIE_SECRET`: the output of `openssl rand -base64 32 | tr -- '+/' '-_'`
   - `OAUTH2_PROXY_EMAIL_DOMAINS`: your Workspace domains, comma-separated, for example `itule.me,safiri.app`

To sign everyone out (for example, after someone leaves), change `OAUTH2_PROXY_COOKIE_SECRET` and redeploy.

# Acknowledgements

[auto-setup-override.sh](temporal-cluster/server/auto-setup/auto-setup-override.sh) is based on Temporal's [auto-setup.sh script](https://github.com/temporalio/docker-builds/blob/main/docker/auto-setup.sh), with some modifications made to better accommodate Render's architecture.
