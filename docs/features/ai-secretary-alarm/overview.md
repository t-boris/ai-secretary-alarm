---
type: feature
id: ai-secretary-alarm
title: AI Secretary Alarm
status: implementing
epic: 9
issues: ["#1", "#2", "#3", "#4", "#5", "#6", "#7", "#8"]
owner: Boris Tsekinovsky
created: 2026-09-30
provenance: Created from the new-project intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: known
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
understanding_notes:
  Target Users: Один пользователь — автор (DEC-002).
  Dependencies: Облачный ИИ, Google Calendar, картографический сервис с учётом пробок.
  Failure Scenarios: Пропущенные напоминания при сне Mac, изменения/удаления в календаре решены.
  Permissions: Один собственный аккаунт Google, свой API-ключ.
  Security: Личный инструмент, собственные ключи и аккаунт.
  Problem: Ручное создание событий трудоёмко, стандартные уведомления легко пропустить.
  Primary Workflow: Голос → разбор ИИ → уточнения → Google Calendar → напоминание.
  Data Model: Приложение хранит только созданные им события и зеркалит их в календарь.
  Notifications: Звук и речь один раз, затем постоянное уведомление на экране (решение по Q-008).
  Analytics: Для личного инструмента не требуется.
  Acceptance Criteria: Критерии есть у всех требований; остальное — детали для ревью.
questions_left: 0
confirmed: 2026-09-30
---

# AI Secretary Alarm

## Idea

A small always-available app that the user speaks natural-language requests to, such as "remind me about a meeting with Manoj at 10:30 today" or "training every Mon/Wed/Fri at 6 pm". The user says "iOS" but describes an app in the top menu bar, which suggests macOS; this is an inference to confirm. An AI parses the request and asks clarifying questions when needed (e.g. location). It then creates the event in Google Calendar and later alerts the user like an alarm: a sound plus a spoken explanation, including preparation hints. For off-site events it gives a 'time to leave' reminder that accounts for travel time.

## Problem

Creating reminders and calendar events by hand takes effort. Standard calendar notifications are easy to miss and ignore preparation and travel time. The user wants to state an intent once by voice and be reliably reminded at the right moment with no further manual work.

## Scope

IN (v1): voice input (possibly text too) in an always-available app; AI parsing of one-off and recurring events; a clarifying dialogue for missing details (location, reminder lead time); creating events in the user's Google Calendar; alarm-like reminders with sound and speech; a travel-time-aware 'leave now' reminder for off-site events. OUT (v1, assumed): multiple users, non-Google calendars, inviting or negotiating with attendees, deep meeting-preparation content.

## GitHub issues

[Epic #9](https://github.com/t-boris/ai-secretary-alarm/issues/9) tracks the v1 implementation. Each task in the [implementation plan](implementation/plan.md) already has its own issue:

| Task | Issue | Coverage |
| --- | --- | --- |
| I-1 | [#1](https://github.com/t-boris/ai-secretary-alarm/issues/1) | Menu bar app, settings, Keychain, local storage |
| I-2 | [#2](https://github.com/t-boris/ai-secretary-alarm/issues/2) | Voice capture, transcription, AI parsing |
| I-3 | [#3](https://github.com/t-boris/ai-secretary-alarm/issues/3) | Clarifying dialogue and confirmation |
| I-4 | [#4](https://github.com/t-boris/ai-secretary-alarm/issues/4) | Saved places and geocoding |
| I-5 | [#5](https://github.com/t-boris/ai-secretary-alarm/issues/5) | Google OAuth, event creation, tagging |
| I-6 | [#6](https://github.com/t-boris/ai-secretary-alarm/issues/6) | Calendar change sync |
| I-7 | [#7](https://github.com/t-boris/ai-secretary-alarm/issues/7) | Reminder scheduling and alarm playback |
| I-8 | [#8](https://github.com/t-boris/ai-secretary-alarm/issues/8) | Location-aware lead time and two-stage off-site alarms |
