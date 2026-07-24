"""ACP bridge — relay tasks to coding agents with runtime management."""

import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from hermes_agent.acp.diagnostics import run_diagnostics
from hermes_agent.acp.models import AcpRuntime, AcpTask
from hermes_agent.acp.task_service import get_task_service
from hermes_agent.security import verify_token

router = APIRouter(tags=["acp"], dependencies=[Depends(verify_token)])
_log = logging.getLogger("hermes-agent")

DEFAULT_TIMEOUT = 600


class AcpTaskRequest(BaseModel):
    prompt: str = Field(..., description="The task to delegate")
    model: Optional[str] = Field(None, description="Model ID (e.g. deepseek-chat)")
    timeout: int = Field(DEFAULT_TIMEOUT, ge=1, le=3600, description="Max wait in seconds")
    conversation_id: Optional[str] = Field(None, description="Conversation ID for session reuse")


@router.post("/acp/tasks", summary="Submit a task to the ACP coding agent")
async def acp_submit_task(body: AcpTaskRequest):
    svc = get_task_service()
    conversation_id = body.conversation_id or "default"
    task_id = svc.submit_and_return_task_id(
        conversation_id=conversation_id,
        prompt=body.prompt,
        model=body.model or "",
        timeout=body.timeout,
    )
    _log.info("ACP task %s submitted (async)", task_id)
    return {"task_id": task_id, "status": "running"}


@router.get("/acp/tasks/{task_id}", summary="Get task status and result")
async def acp_task_status(task_id: str):
    svc = get_task_service()
    result = svc.poll(task_id)
    if not result:
        raise HTTPException(status_code=404, detail=f"Task {task_id} not found")
    return result


@router.get("/acp/tasks/{task_id}/live", summary="Get live OpenCode session messages for a task")
async def acp_task_live(task_id: str):
    from hermes_agent.acp.models import AcpConversation, AcpRuntime, AcpTask

    task = AcpTask.get_by_task_id(task_id)
    if not task:
        raise HTTPException(status_code=404, detail=f"Task {task_id} not found")

    conv_id = task.conversation_id
    if not conv_id:
        return {"messages": [], "note": "no conversation attached yet"}

    conv = AcpConversation.get_by_conversation_id(conv_id)
    if not conv or not conv.runtime_id:
        return {"messages": [], "note": "no runtime attached"}

    runtime = AcpRuntime.get_or_none(AcpRuntime.runtime_id == conv.runtime_id)
    if not runtime:
        return {"messages": [], "note": "runtime not found"}

    try:
        import httpx

        base = runtime.endpoint.rstrip("/")
        sid = conv.upstream_session_id or ""
        if not sid:
            return {"messages": [], "note": "no upstream session yet"}
        resp = httpx.get(f"{base}/session/{sid}/message", timeout=5)
        resp.raise_for_status()
        messages = resp.json()
        return {"session_id": sid, "endpoint": runtime.endpoint, "count": len(messages), "messages": messages}
    except Exception as exc:
        return {"error": str(exc), "endpoint": runtime.endpoint}


@router.delete("/acp/tasks/{task_id}", summary="Cancel a running task")
async def acp_task_cancel(task_id: str):
    svc = get_task_service()
    result = svc.cancel(task_id)
    if not result:
        raise HTTPException(status_code=404, detail=f"Task {task_id} not found")
    return result


@router.get("/acp/status", summary="ACP system status and diagnostics")
async def acp_status():
    runtimes = AcpRuntime.get_ready_managed()
    tasks_running = AcpTask.count_running()
    return {
        "runtimes": [{"runtime_id": r["runtime_id"], "endpoint": r["endpoint"], "status": r["status"]} for r in runtimes],
        "runtimes_count": len(runtimes),
        "tasks_running": tasks_running,
    }


@router.get("/acp/sessions", summary="List active ACP sessions")
async def acp_list_sessions():
    runtimes = AcpRuntime.get_ready_managed()
    return {"sessions": runtimes, "count": len(runtimes)}


@router.get("/acp/diagnostics", summary="Run ACP diagnostics")
async def acp_diagnostics(agent_type: str = Query("opencode")):
    return run_diagnostics(agent_type)


@router.get("/acp/runtimes/{runtime_id}/live", summary="Get live OpenCode session messages for a runtime", dependencies=[])
async def acp_runtime_live(runtime_id: str):
    from hermes_agent.acp.models import AcpConversation, AcpRuntime

    import httpx

    runtime = AcpRuntime.get_or_none(AcpRuntime.runtime_id == runtime_id)
    if not runtime:
        raise HTTPException(status_code=404, detail=f"Runtime {runtime_id} not found")

    convs = list(AcpConversation.select().where(AcpConversation.runtime_id == runtime_id))
    if not convs:
        return {"messages": [], "note": "no conversation attached to this runtime"}

    sid = convs[0].upstream_session_id
    if not sid:
        return {"messages": [], "note": "no upstream session yet"}

    try:
        resp = httpx.get(f"{runtime.endpoint.rstrip('/')}/session/{sid}/message", timeout=5)
        resp.raise_for_status()
        messages = resp.json()
        return {"session_id": sid, "endpoint": runtime.endpoint, "count": len(messages), "messages": messages}
    except Exception as exc:
        return {"error": str(exc), "endpoint": runtime.endpoint}
