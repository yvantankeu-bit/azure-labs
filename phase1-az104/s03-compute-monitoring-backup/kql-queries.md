# KQL queries – S03 lab 5

Queries run in the Log Analytics workspace (`Logs`, KQL mode). Pattern: **table → filter (`where`) → columns (`project`) → sort (`sort by`)**, plus `take` to explore and `summarize` to group.

## Explore a table
```kusto
Heartbeat
| take 5
```
`take` returns a few random rows: the first reflex on an unknown table.

## Is each VM alive? (agent heartbeat)
```kusto
Heartbeat
| summarize LastSeen = max(TimeGenerated), Beats = count() by Computer
```
One row per machine. A `LastSeen` older than ~5 minutes means the VM or its agent stopped reporting.

## Memory used inside a VM (needs the Azure Monitor Agent + DCR)
```kusto
Perf
| where ObjectName == "Memory" and CounterName == "% Used Memory"
| project TimeGenerated, Computer, CounterValue
| sort by TimeGenerated desc
| take 10
```

## Who did what in a resource group (activity log)
```kusto
AzureActivity
| where ResourceGroup =~ "rg-lab-s03-monitor"
| where ActivityStatusValue == "Success"
| project TimeGenerated, Caller, OperationNameValue
| sort by TimeGenerated desc
```
`=~` is case-insensitive: the activity log often stores resource group names in upper case, and `==` would silently return nothing.

## Who deleted something
```kusto
AzureActivity
| where OperationNameValue contains "delete"
| project TimeGenerated, Caller, ResourceGroup, OperationNameValue, ActivityStatusValue
| sort by TimeGenerated desc
```
Change `"delete"` to `"write"` to see creations and updates. One operation appears several times (`Start`, `Accept`, `Success`/`Failure`): filter on `ActivityStatusValue` to keep the outcome. A `Caller` that is a GUID instead of an e-mail is an application identity (service principal or managed identity), not a person.

## Notes
- Times in the workspace are **UTC**.
- The last minute of data is often incomplete; data from a new agent takes 5–15 minutes to arrive.
