"""
Google Cloud Billing Budget Alert & Programmatic Hard-Stop Enforcer
Cloud Functions 2nd Gen (Python 3.12) triggered via Eventarc / Cloud Pub/Sub.

Supported Enforcement Modes (ENFORCEMENT_MODE):
  1. DRY_RUN               : Logs the budget breach and sends Slack/Webhook notifications without modifying resources.
  2. STOP_COMPUTE_AND_APIS : Stops all running Compute Engine VMs across all zones and disables configured billable APIs.
  3. UNLINK_BILLING        : Detaches the Google Cloud Project from its Billing Account (official GCP nuclear hard stop).
"""

import base64
import json
import os
import sys
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

import functions_framework
from google.cloud import secretmanager
from googleapiclient import discovery

# Core services that must never be disabled when running inside the target project
PROTECTED_ENFORCER_APIS = {
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "eventarc.googleapis.com",
    "secretmanager.googleapis.com",
    "logging.googleapis.com",
    "cloudbilling.googleapis.com",
    "billingbudgets.googleapis.com",
    "serviceusage.googleapis.com",
}


def log_structured(severity: str, message: str, **kwargs: Any) -> None:
    """Emits a structured JSON log entry compatible with Google Cloud Logging."""
    entry = {"severity": severity, "message": message, **kwargs}
    print(json.dumps(entry), file=sys.stderr if severity in ("ERROR", "CRITICAL") else sys.stdout)


def get_slack_webhook_url(project_id: str, secret_id: str, version: str = "latest") -> Optional[str]:
    """Fetches the Slack Incoming Webhook URL from Secret Manager before any destructive action."""
    if not project_id or not secret_id:
        return None
    try:
        client = secretmanager.SecretManagerServiceClient()
        name = f"projects/{project_id}/secrets/{secret_id}/versions/{version}"
        response = client.access_secret_version(request={"name": name})
        url = response.payload.data.decode("UTF-8").strip()
        return url if url.startswith("https://") else None
    except Exception as exc:
        log_structured("WARNING", f"Could not fetch Slack webhook secret '{secret_id}': {exc}")
        return None


def parse_pubsub_payload(cloud_event: Any) -> Dict[str, Any]:
    """Decodes the base64 Cloud Billing Budget JSON message from the Pub/Sub CloudEvent."""
    if isinstance(cloud_event, dict):
        data_root = cloud_event.get("data", {})
    else:
        data_root = getattr(cloud_event, "data", {}) or {}

    pubsub_message = data_root.get("message", {})
    b64_data = pubsub_message.get("data", "")
    if not b64_data:
        raise ValueError("Pub/Sub message contains no 'data' field.")

    raw_json = base64.b64decode(b64_data).decode("utf-8")
    return json.loads(raw_json)


def evaluate_breach(
    payload: Dict[str, Any],
    hard_stop_threshold_percent: float,
    trigger_on_forecast: bool,
) -> Tuple[bool, str, float]:
    """
    Determines whether the budget notification requires hard-stop enforcement.
    Returns (should_enforce, breach_reason, utilization_ratio).
    """
    cost_amount = float(payload.get("costAmount", 0.0))
    budget_amount = float(payload.get("budgetAmount", 0.0))
    alert_threshold = payload.get("alertThresholdExceeded")
    forecast_threshold = payload.get("forecastThresholdExceeded")

    ratio = (cost_amount / budget_amount) if budget_amount > 0 else 0.0

    if budget_amount > 0 and ratio >= hard_stop_threshold_percent:
        return (
            True,
            f"Actual spend ({ratio * 100:.1f}%) reached or exceeded hard-stop threshold ({hard_stop_threshold_percent * 100:.1f}%)",
            ratio,
        )

    if alert_threshold is not None and float(alert_threshold) >= hard_stop_threshold_percent and ratio >= hard_stop_threshold_percent:
        return (
            True,
            f"Actual threshold rule ({float(alert_threshold) * 100:.0f}%) breached",
            ratio,
        )

    if trigger_on_forecast and forecast_threshold is not None and float(forecast_threshold) >= hard_stop_threshold_percent:
        return (
            True,
            f"Forecasted spend threshold ({float(forecast_threshold) * 100:.0f}%) breached with TRIGGER_ON_FORECAST_BREACH=true",
            ratio,
        )

    return (False, "Spend is below the hard-stop enforcement threshold", ratio)


def stop_all_compute_instances(project_id: str) -> List[str]:
    """Stops all RUNNING Compute Engine instances across all zones in the target project."""
    stopped_vms: List[str] = []
    compute = discovery.build("compute", "v1", cache_discovery=False)
    request = compute.instances().aggregatedList(project=project_id)

    while request is not None:
        response = request.execute()
        items = response.get("items", {})
        for zone_key, zone_data in items.items():
            instances = zone_data.get("instances", [])
            zone_name = zone_key.replace("zones/", "")
            for inst in instances:
                status = inst.get("status")
                inst_name = inst.get("name")
                if status == "RUNNING" and inst_name:
                    try:
                        compute.instances().stop(
                            project=project_id,
                            zone=zone_name,
                            instance=inst_name,
                        ).execute()
                        stopped_vms.append(f"{zone_name}/{inst_name}")
                        log_structured("NOTICE", f"Initiated stop for VM {zone_name}/{inst_name}", project_id=project_id)
                    except Exception as exc:
                        log_structured("ERROR", f"Failed to stop VM {zone_name}/{inst_name}: {exc}", project_id=project_id)

        request = compute.instances().aggregatedList_next(previous_request=request, previous_response=response)

    return stopped_vms


def disable_target_apis(
    project_id: str,
    apis_to_disable: List[str],
    protect_enforcer: bool = True,
) -> List[str]:
    """Disables the configured list of billable Google Cloud APIs via Service Usage API."""
    disabled_apis: List[str] = []
    serviceusage = discovery.build("serviceusage", "v1", cache_discovery=False)

    for api in apis_to_disable:
        api_clean = api.strip()
        if not api_clean:
            continue
        if protect_enforcer and api_clean in PROTECTED_ENFORCER_APIS:
            log_structured(
                "WARNING",
                f"Skipping protected enforcer service '{api_clean}' due to PROTECT_ENFORCER_SERVICES=true",
                project_id=project_id,
            )
            continue

        resource_name = f"projects/{project_id}/services/{api_clean}"
        try:
            serviceusage.services().disable(
                name=resource_name,
                body={"disableDependentServices": True},
            ).execute()
            disabled_apis.append(api_clean)
            log_structured("NOTICE", f"Disabled billable service: {api_clean}", project_id=project_id)
        except Exception as exc:
            log_structured("ERROR", f"Failed to disable service {api_clean}: {exc}", project_id=project_id)

    return disabled_apis


def unlink_project_billing(project_id: str) -> str:
    """Unlinks the project from its Cloud Billing Account to immediately stop all billable usage."""
    billing = discovery.build("cloudbilling", "v1", cache_discovery=False)
    project_resource = f"projects/{project_id}"

    billing_info = billing.projects().getBillingInfo(name=project_resource).execute()
    if not billing_info.get("billingEnabled", False):
        log_structured("NOTICE", f"Billing is already disabled on {project_resource}.", project_id=project_id)
        return "Billing was already disabled (no-op)"

    previous_account = billing_info.get("billingAccountName", "unknown")
    billing.projects().updateBillingInfo(
        name=project_resource,
        body={"billingAccountName": ""},
    ).execute()

    msg = f"Unlinked billing account ({previous_account}) from {project_resource}"
    log_structured("CRITICAL", msg, project_id=project_id, previous_billing_account=previous_account)
    return msg


def execute_enforcement(
    project_id: str,
    enforcement_mode: str,
    apis_to_disable: List[str],
    protect_enforcer: bool,
) -> Dict[str, Any]:
    """Dispatches the configured hard-stop action and returns an execution summary."""
    mode = enforcement_mode.upper().strip()

    if mode == "DRY_RUN":
        summary = (
            f"[DRY_RUN] Simulated hard stop for project '{project_id}'. "
            f"Would stop running VMs and disable APIs ({', '.join(apis_to_disable)}) or unlink billing."
        )
        log_structured("WARNING", summary, project_id=project_id, enforcement_mode=mode)
        return {"mode": mode, "executed": False, "summary": summary, "details": []}

    if mode == "STOP_COMPUTE_AND_APIS":
        stopped_vms = stop_all_compute_instances(project_id)
        disabled_apis = disable_target_apis(project_id, apis_to_disable, protect_enforcer)
        details = [
            f"Stopped VMs ({len(stopped_vms)}): {', '.join(stopped_vms) if stopped_vms else 'none running'}",
            f"Disabled APIs ({len(disabled_apis)}): {', '.join(disabled_apis) if disabled_apis else 'none'}",
        ]
        summary = " | ".join(details)
        log_structured("CRITICAL", f"Executed STOP_COMPUTE_AND_APIS: {summary}", project_id=project_id)
        return {"mode": mode, "executed": True, "summary": summary, "details": details}

    if mode == "UNLINK_BILLING":
        result_msg = unlink_project_billing(project_id)
        return {"mode": mode, "executed": True, "summary": result_msg, "details": [result_msg]}

    raise ValueError(f"Unsupported ENFORCEMENT_MODE: {enforcement_mode}")


def build_slack_blocks(
    payload: Dict[str, Any],
    project_id: str,
    region: str,
    should_enforce: bool,
    breach_reason: str,
    enforcement_result: Optional[Dict[str, Any]],
) -> Dict[str, Any]:
    """Constructs a Slack Block Kit card for both warning thresholds and hard-stop breaches."""
    cost = float(payload.get("costAmount", 0.0))
    budget = float(payload.get("budgetAmount", 0.0))
    currency = payload.get("currencyCode", "SGD")
    display_name = payload.get("budgetDisplayName", f"{project_id} Billing Guardrail")
    actual_threshold = payload.get("alertThresholdExceeded")
    forecast_threshold = payload.get("forecastThresholdExceeded")

    pct = (cost / budget * 100.0) if budget > 0 else 0.0

    if should_enforce:
        header_text = f"🛑 HARD-STOP TRIGGERED - {display_name}"
    elif pct >= 90.0 or (actual_threshold and float(actual_threshold) >= 0.90):
        header_text = f"🚨 CRITICAL BUDGET ALERT - {display_name}"
    elif pct >= 80.0 or (actual_threshold and float(actual_threshold) >= 0.80):
        header_text = f"⚠️ BUDGET WARNING - {display_name}"
    elif forecast_threshold is not None:
        header_text = f"📈 FORECASTED SPEND ALERT - {display_name}"
    else:
        header_text = f"ℹ️ BUDGET ADVISORY - {display_name}"

    if actual_threshold is not None:
        threshold_label = f"Actual {float(actual_threshold) * 100:.0f}%"
    elif forecast_threshold is not None:
        threshold_label = f"Forecast {float(forecast_threshold) * 100:.0f}%"
    else:
        threshold_label = "Periodic Update"

    blocks: List[Dict[str, Any]] = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": header_text[:150], "emoji": True},
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*Current Spend:*\n`{currency} {cost:,.2f}`"},
                {"type": "mrkdwn", "text": f"*Monthly Budget:*\n`{currency} {budget:,.2f}`"},
                {"type": "mrkdwn", "text": f"*Utilization:*\n`{pct:.1f}%`"},
                {"type": "mrkdwn", "text": f"*Threshold Crossed:*\n`{threshold_label}`"},
            ],
        },
    ]

    if should_enforce and enforcement_result:
        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"*Hard-Stop Enforcement (`{enforcement_result['mode']}`):*\n"
                        f"• *Reason:* {breach_reason}\n"
                        f"• *Action Taken:* {enforcement_result['summary']}"
                    ),
                },
            }
        )

    blocks.extend(
        [
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": f"📍 Project: `{project_id}` | Region: `{region}`",
                    }
                ],
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "View Cloud Billing Reports"},
                        "url": f"https://console.cloud.google.com/billing/reports?project={project_id}",
                        "style": "danger" if should_enforce else ("primary" if pct >= 80 else "default"),
                    }
                ],
            },
        ]
    )

    return {"blocks": blocks}


def send_slack_notification(webhook_url: str, slack_payload: Dict[str, Any]) -> bool:
    """Posts the formatted Block Kit payload to the Slack Incoming Webhook."""
    try:
        req = urllib.request.Request(
            webhook_url,
            data=json.dumps(slack_payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            log_structured("INFO", f"Slack notification delivered (HTTP {resp.status}).")
            return True
    except Exception as exc:
        log_structured("ERROR", f"Failed to deliver Slack notification: {exc}")
        return False


@functions_framework.cloud_event
def handle_budget_notification(cloud_event: Any) -> str:
    """Cloud Functions 2nd Gen entry point for Cloud Billing Budget Pub/Sub events."""
    project_id = os.environ.get("PROJECT_ID", "")
    region = os.environ.get("REGION", "asia-southeast1")
    enforcement_mode = os.environ.get("ENFORCEMENT_MODE", "STOP_COMPUTE_AND_APIS")
    hard_stop_threshold = float(os.environ.get("HARD_STOP_THRESHOLD_PERCENT", "1.0"))
    trigger_on_forecast = os.environ.get("TRIGGER_ON_FORECAST_BREACH", "false").lower() == "true"
    apis_raw = os.environ.get("APIS_TO_DISABLE", "aiplatform.googleapis.com,compute.googleapis.com")
    apis_to_disable = [a.strip() for a in apis_raw.split(",") if a.strip()]
    protect_enforcer = os.environ.get("PROTECT_ENFORCER_SERVICES", "true").lower() == "true"
    enable_slack = os.environ.get("ENABLE_SLACK_WEBHOOK", "false").lower() == "true"
    slack_secret_id = os.environ.get("SLACK_SECRET_ID", "")

    try:
        payload = parse_pubsub_payload(cloud_event)
    except Exception as exc:
        log_structured("ERROR", f"Invalid Cloud Billing Pub/Sub payload: {exc}")
        return "INVALID_PAYLOAD"

    should_enforce, breach_reason, ratio = evaluate_breach(
        payload=payload,
        hard_stop_threshold_percent=hard_stop_threshold,
        trigger_on_forecast=trigger_on_forecast,
    )

    log_structured(
        "NOTICE" if should_enforce else "INFO",
        f"Received budget update for '{payload.get('budgetDisplayName', project_id)}': "
        f"spend={payload.get('costAmount')} / budget={payload.get('budgetAmount')} "
        f"({ratio * 100:.1f}%), should_enforce={should_enforce}",
        project_id=project_id,
        enforcement_mode=enforcement_mode,
        should_enforce=should_enforce,
    )

    # Pre-fetch Slack webhook from Secret Manager BEFORE executing UNLINK_BILLING or disabling APIs
    webhook_url: Optional[str] = None
    if enable_slack and slack_secret_id:
        webhook_url = get_slack_webhook_url(project_id, slack_secret_id)

    enforcement_result: Optional[Dict[str, Any]] = None
    if should_enforce:
        try:
            enforcement_result = execute_enforcement(
                project_id=project_id,
                enforcement_mode=enforcement_mode,
                apis_to_disable=apis_to_disable,
                protect_enforcer=protect_enforcer,
            )
        except Exception as exc:
            log_structured("CRITICAL", f"Hard-stop enforcement failed: {exc}", project_id=project_id)
            enforcement_result = {
                "mode": enforcement_mode,
                "executed": False,
                "summary": f"Enforcement error: {exc}",
                "details": [],
            }

    # Send Slack alert if configured and a threshold was crossed (or hard stop triggered)
    has_threshold_event = (
        should_enforce
        or payload.get("alertThresholdExceeded") is not None
        or payload.get("forecastThresholdExceeded") is not None
    )
    if webhook_url and has_threshold_event:
        slack_payload = build_slack_blocks(
            payload=payload,
            project_id=project_id,
            region=region,
            should_enforce=should_enforce,
            breach_reason=breach_reason,
            enforcement_result=enforcement_result,
        )
        send_slack_notification(webhook_url, slack_payload)

    return "ENFORCED" if should_enforce else "OK"

