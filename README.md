# AI Secretary Alarm

A small always-available app that the user speaks natural-language requests to, such as "remind me about a meeting with Manoj at 10:30 today" or "training every Mon/Wed/Fri at 6 pm". The user says "iOS" but describes an app in the top menu bar, which suggests macOS; this is an inference to confirm. An AI parses the request and asks clarifying questions when needed (e.g. location). It then creates the event in Google Calendar and later alerts the user like an alarm: a sound plus a spoken explanation, including preparation hints. For off-site events it gives a 'time to leave' reminder that accounts for travel time.

## Problem

Creating reminders and calendar events by hand takes effort. Standard calendar notifications are easy to miss and ignore preparation and travel time. The user wants to state an intent once by voice and be reliably reminded at the right moment with no further manual work.

## Scope

IN (v1): voice input (possibly text too) in an always-available app; AI parsing of one-off and recurring events; a clarifying dialogue for missing details (location, reminder lead time); creating events in the user's Google Calendar; alarm-like reminders with sound and speech; a travel-time-aware 'leave now' reminder for off-site events. OUT (v1, assumed): multiple users, non-Google calendars, inviting or negotiating with attendees, deep meeting-preparation content.

## Specification

The confirmed brief, decisions and requirements are in [`docs/features/ai-secretary-alarm/`](docs/features/ai-secretary-alarm/overview.md). Open this folder in MarkView to continue them.

### Requirements

- REQ-001 Natural-language voice capture
- REQ-002 Clarifying questions
- REQ-003 Google Calendar sync
- REQ-004 Alarm-style spoken reminder
- REQ-005 Location-aware lead time
