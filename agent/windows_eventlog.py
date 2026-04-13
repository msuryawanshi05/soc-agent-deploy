"""
Windows Event Log Monitor
Collects events from Windows Event Logs (Security, System, Application)
Requires: pywin32 (Windows only)
"""

import sys
import time
from datetime import datetime
from typing import List, Dict, Optional

if sys.platform == 'win32':
    import win32evtlog
    import win32evtlogutil
    import win32security
    import win32con
    import pywintypes

class WindowsEventLogMonitor:
    def __init__(self, log_names: List[str] = None):
        if sys.platform != 'win32':
            raise RuntimeError("WindowsEventLogMonitor only works on Windows")
        self.log_names = log_names or ["System", "Security", "Application"]
        self.enabled_logs = []
        self.last_record_numbers = {}
        self._initialize_bookmarks()
    
    def _initialize_bookmarks(self):
        for log_name in self.log_names:
            try:
                hand = win32evtlog.OpenEventLog(None, log_name)
                flags = win32evtlog.EVENTLOG_BACKWARDS_READ | win32evtlog.EVENTLOG_SEQUENTIAL_READ
                events = win32evtlog.ReadEventLog(hand, flags, 0)
                if events:
                    self.last_record_numbers[log_name] = events[0].RecordNumber
                else:
                    self.last_record_numbers[log_name] = 0
                win32evtlog.CloseEventLog(hand)
                self.enabled_logs.append(log_name)
            except Exception:
                self.last_record_numbers[log_name] = 0
    
    def collect_new_events(self) -> List[Dict]:
        all_events = []
        for log_name in self.enabled_logs:
            try:
                events = self._read_log(log_name)
                all_events.extend(events)
            except Exception:
                pass
        return all_events
    
    def _read_log(self, log_name: str) -> List[Dict]:
        events = []
        try:
            hand = win32evtlog.OpenEventLog(None, log_name)
            flags = win32evtlog.EVENTLOG_BACKWARDS_READ | win32evtlog.EVENTLOG_SEQUENTIAL_READ
            raw_events = win32evtlog.ReadEventLog(hand, flags, 0)
            new_bookmark = self.last_record_numbers[log_name]
            for event in raw_events:
                if event.RecordNumber <= self.last_record_numbers[log_name]:
                    break
                if event.RecordNumber > new_bookmark:
                    new_bookmark = event.RecordNumber
                parsed = self._parse_event(event, log_name)
                events.append(parsed)
            self.last_record_numbers[log_name] = new_bookmark
            events.reverse()
            win32evtlog.CloseEventLog(hand)
        except Exception:
            pass
        return events
    
    def _parse_event(self, event, log_name: str) -> Dict:
        try:
            event_type = {
                win32con.EVENTLOG_ERROR_TYPE: "ERROR",
                win32con.EVENTLOG_WARNING_TYPE: "WARNING",
                win32con.EVENTLOG_INFORMATION_TYPE: "INFO",
                win32con.EVENTLOG_AUDIT_SUCCESS: "AUDIT_SUCCESS",
                win32con.EVENTLOG_AUDIT_FAILURE: "AUDIT_FAILURE"
            }.get(event.EventType, "UNKNOWN")
            try:
                message = win32evtlogutil.SafeFormatMessage(event, log_name)
            except:
                message = "(Unable to format message)"
            username = "N/A"
            if event.Sid:
                try:
                    domain, user, typ = win32security.LookupAccountSid(None, event.Sid)
                    username = f"{domain}\\{user}"
                except:
                    username = str(event.Sid)
            return {
                "timestamp": event.TimeGenerated.isoformat(),
                "log_name": log_name,
                "event_id": event.EventID & 0xFFFF,
                "event_type": event_type,
                "source": event.SourceName,
                "category": event.EventCategory,
                "username": username,
                "computer": event.ComputerName,
                "message": message,
                "record_number": event.RecordNumber
            }
        except Exception as e:
            return {
                "timestamp": datetime.now().isoformat(),
                "log_name": log_name,
                "event_id": 0,
                "event_type": "ERROR",
                "source": "EventLogParser",
                "message": f"Failed to parse event: {e}",
                "record_number": event.RecordNumber if hasattr(event, 'RecordNumber') else 0
            }

def format_for_soc(event: Dict) -> str:
    return f"[{event['timestamp']}] EventID={event['event_id']} Type={event['event_type']} Source={event['source']} User={event.get('username', 'N/A')} Computer={event.get('computer', 'N/A')} Message: {event['message']}"
