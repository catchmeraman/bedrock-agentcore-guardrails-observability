// ---------------------------------------------------------------------------
// Sample Cedar policy for an AgentCore Gateway Policy Engine
//
// Cedar is DEFAULT-DENY: if no `permit` matches, the action is denied.
// A `forbid` ALWAYS overrides any `permit`.
//
// Principal  = the workload identity of the agent (or a group it belongs to)
// Action     = the tool being invoked, exposed via the Gateway as an MCP tool
// Resource   = the gateway target / tool resource
//
// NOTE: Action/resource identifiers below are ILLUSTRATIVE. Validate the exact
// entity types and attribute names against the Cedar schema that the Policy
// Engine derives from YOUR gateway's tool catalog before deploying.
// ---------------------------------------------------------------------------

// 1) Admins may invoke any tool, unconditionally.
permit(
    principal in Group::"Admins",
    action,
    resource
);

// 2) Standard users may invoke the read-only weather tool, but ONLY during
//    business hours (09:00-17:00 UTC). `context.hourOfDay` is supplied by the
//    Gateway at evaluation time.
permit(
    principal in Group::"Users",
    action == Action::"weather___get_forecast",
    resource
)
when {
    context.hourOfDay >= 9 && context.hourOfDay < 17
};

// 3) Explicitly forbid ALL users (including Admins, because forbid wins) from
//    invoking any tool whose name indicates a destructive write/delete action.
//    This is a guardrail against accidental or malicious high-impact calls.
forbid(
    principal,
    action,
    resource
)
when {
    action.name like "*delete*" || action.name like "*purge*"
};
