import json
import time

class LogEvent:
    def __init__(self, agent_id: str, hostname: str, source: str, raw_log: str, timestamp: float = None):
        self.agent_id = agent_id
        self.hostname = hostname
        self.source = source
        self.raw_log = raw_log
        self.timestamp = timestamp if timestamp is not None else time.time()

    @classmethod
    def from_json(cls, raw: str):
        data = json.loads(raw)
        return cls(
            agent_id=data.get("agent_id", ""),
            hostname=data.get("hostname", ""),
            source=data.get("source", ""),
            raw_log=data.get("raw_log", ""),
            timestamp=data.get("timestamp")
        )

    def to_dict(self):
        return self.__dict__

class Alert:
    def __init__(self, rule_id: str, rule_name: str, severity: str, agent_id: str, hostname: str, matched_log: str, timestamp: float = None):
        self.rule_id = rule_id
        self.rule_name = rule_name
        self.severity = severity
        self.agent_id = agent_id
        self.hostname = hostname
        self.matched_log = matched_log
        self.timestamp = timestamp if timestamp is not None else time.time()

    def to_dict(self):
        return self.__dict__

    def __repr__(self):
        return f"[ALERT][{self.severity}] {self.rule_name} on {self.hostname}"
