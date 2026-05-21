from datetime import datetime, timezone
import sys

class AgentLogger:
    """
    Logs all agent decisions to console + in-memory trace.
    Safe against UnicodeEncodeError on Windows consoles — a crash here
    would silently kill the orchestrator asyncio task.
    """

    def __init__(self, firestore_db=None):
        self.db   = firestore_db
        self.logs = []   # In-memory trace for GET /trace endpoint

    def log(self, agent: str, message: str, session_id: str = None, level: str = "INFO"):
        icons = {
            "INFO": "[INFO]", "WARN": "[WARN]", "ERROR": "[ERROR]",
            "SUCCESS": "[OK]", "RECOVERY": "[RECOVERY]", "LEARNING": "[LEARNING]"
        }
        entry = {
            "agent":      agent,
            "message":    message,
            "level":      level,
            "icon":       icons.get(level, "•"),
            "session_id": session_id,
            "timestamp":  datetime.now(timezone.utc).isoformat(),
        }
        # Always store in memory — even if print fails
        self.logs.append(entry)

        # Safe print: encode to current console encoding, replace unknown chars
        # This prevents UnicodeEncodeError from crashing the asyncio task
        try:
            line = f"[{agent}] [{level}] {message}"
            safe = line.encode(sys.stdout.encoding or "utf-8", errors="replace").decode(
                sys.stdout.encoding or "utf-8", errors="replace"
            )
            print(safe)
        except Exception:
            # Last resort — strip to ASCII
            try:
                print(f"[{agent}] [{level}] {message.encode('ascii', errors='replace').decode('ascii')}")
            except Exception:
                pass   # Never crash the caller

        if self.db:
            try:
                self.db.collection("agent_trace").add(entry)
            except Exception:
                pass

    def get_recent(self, limit: int = 50):
        return self.logs[-limit:]


def safe_print(msg: str):
    """
    Windows-safe print that never raises UnicodeEncodeError.
    Import this in every agent instead of bare print() for any message
    that might contain emoji or non-ASCII characters.
    """
    try:
        enc  = sys.stdout.encoding or "utf-8"
        safe = msg.encode(enc, errors="replace").decode(enc, errors="replace")
        print(safe)
    except Exception:
        try:
            print(msg.encode("ascii", errors="replace").decode("ascii"))
        except Exception:
            pass  # Never crash the caller
