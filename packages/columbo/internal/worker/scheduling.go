package worker

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"columbo/internal/agent"
	"columbo/internal/ticket"

	"github.com/rs/zerolog/log"
)

const (
	ticketContextAttempts   = 3
	ticketContextRetryDelay = time.Second
	maxCompletedTickets     = 4096
)

type Options struct {
	TicketQuietPeriod  time.Duration
	FetchTicketContext bool
}

type ticketJob struct {
	investigation agent.Investigation
	due           time.Time
	revision      uint64
	queued        bool
	running       bool
	cancel        context.CancelFunc
	latestMessage uint64
}

type queuedInvestigation struct {
	job      *ticketJob
	revision uint64
}

func (p *Pool) Enqueue(inv agent.Investigation) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stopped {
		return false
	}
	automatic := inv.RequestedBy == "" && inv.TicketThreadID != ""
	if automatic {
		if _, completed := p.completed[inv.TicketThreadID]; completed {
			return true
		}
	}
	previous := p.automatic[inv.TicketThreadID]
	if automatic && previous != nil {
		return true
	}
	if len(p.jobs) >= queueSize && (automatic || previous == nil) {
		return false
	}
	if !automatic && previous != nil {
		if previous.cancel != nil {
			previous.cancel()
		}
		delete(p.jobs, previous)
		delete(p.automatic, inv.TicketThreadID)
	}
	if !automatic && inv.TicketThreadID != "" {
		p.rememberCompleted(inv.TicketThreadID)
	}
	job := &ticketJob{investigation: inv, due: time.Now()}
	if automatic {
		job.due = job.due.Add(p.options.TicketQuietPeriod)
		p.automatic[inv.TicketThreadID] = job
	}
	p.jobs[job] = struct{}{}
	p.signal()
	return true
}

func (p *Pool) RecordActivity(threadID string, activity ticket.Activity) {
	messageID, err := strconv.ParseUint(activity.MessageID, 10, 64)
	if err != nil || messageID == 0 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	job := p.automatic[threadID]
	if job == nil || job.running || activity.AuthorID == "" || activity.AuthorID != job.investigation.DiscordUserID || messageID <= job.latestMessage {
		return
	}
	job.latestMessage = messageID
	job.due = time.Now().Add(p.options.TicketQuietPeriod)
	p.signal()
}

func (p *Pool) rememberCompleted(threadID string) {
	if _, exists := p.completed[threadID]; exists {
		return
	}
	if len(p.completed) >= maxCompletedTickets {
		var oldestID string
		var oldest time.Time
		for id, completedAt := range p.completed {
			if oldest.IsZero() || completedAt.Before(oldest) {
				oldestID, oldest = id, completedAt
			}
		}
		delete(p.completed, oldestID)
	}
	p.completed[threadID] = time.Now()
}

func (p *Pool) signal() {
	select {
	case p.wake <- struct{}{}:
	default:
	}
}

func (p *Pool) schedule(ctx context.Context) {
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()
	for {
		p.mu.Lock()
		if ctx.Err() != nil {
			p.stopped = true
			for job := range p.jobs {
				if job.cancel != nil {
					job.cancel()
				}
			}
			clear(p.jobs)
			clear(p.automatic)
			p.mu.Unlock()
			return
		}
		delay := time.Hour
		now := time.Now()
		for job := range p.jobs {
			if job.queued || job.running {
				continue
			}
			remaining := job.due.Sub(now)
			if remaining <= 0 {
				select {
				case p.queue <- queuedInvestigation{job: job, revision: job.revision}:
					job.queued = true
				default:
				}
			} else if remaining < delay {
				delay = remaining
			}
		}
		p.mu.Unlock()
		timer.Reset(delay)
		select {
		case <-ctx.Done():
		case <-p.wake:
		case <-timer.C:
		}
	}
}

func (p *Pool) runTicket(ctx context.Context, item queuedInvestigation) {
	p.mu.Lock()
	job := item.job
	_, exists := p.jobs[job]
	if !exists || job.revision != item.revision {
		p.mu.Unlock()
		p.signal()
		return
	}
	job.queued = false
	if time.Now().Before(job.due) || ctx.Err() != nil {
		p.mu.Unlock()
		p.signal()
		return
	}
	runCtx, cancel := context.WithCancel(ctx)
	job.cancel = cancel
	job.running = true
	startedAt := time.Now()
	inv := job.investigation
	p.mu.Unlock()
	p.signal()
	defer cancel()
	defer func() {
		p.mu.Lock()
		if job.revision == item.revision {
			delete(p.jobs, job)
			if p.automatic[inv.TicketThreadID] == job {
				delete(p.automatic, inv.TicketThreadID)
				p.rememberCompleted(inv.TicketThreadID)
			}
		}
		p.mu.Unlock()
		p.signal()
	}()
	if p.options.FetchTicketContext && inv.TicketThreadID != "" {
		fresh, err := p.fetchContext(runCtx, inv)
		if err != nil {
			if runCtx.Err() == nil {
				log.Error().Err(err).Str("ticketThreadId", inv.TicketThreadID).Msg("ticket context unavailable")
				noteCtx, noteCancel := context.WithTimeout(runCtx, 30*time.Second)
				defer noteCancel()
				if postErr := p.bot.PostStaffNote(noteCtx, inv.StaffThreadID, "Investigation could not start because the latest ticket conversation was unavailable. Retry the investigation when the bot is available."); postErr != nil {
					log.Error().Err(postErr).Msg("failed to post ticket context failure")
				}
			}
			return
		}
		if fresh.Closed {
			return
		}
		inv.Messages = fresh.Messages
		if inv.RequestedBy == "" && p.deferForOwnerMessage(job, item.revision, startedAt, fresh.Messages) {
			return
		}
	}
	if runCtx.Err() != nil {
		return
	}
	p.process(runCtx, inv)
}

func (p *Pool) fetchContext(ctx context.Context, inv agent.Investigation) (ticket.Context, error) {
	var err error
	for attempt := 0; attempt < ticketContextAttempts; attempt++ {
		var fresh ticket.Context
		fresh, err = p.bot.GetTicketContext(ctx, inv.TicketThreadID)
		if err == nil {
			if fresh.TicketThreadID != inv.TicketThreadID || inv.DiscordUserID == "" || fresh.DiscordUserID != inv.DiscordUserID {
				return ticket.Context{}, errors.New("ticket context identity mismatch")
			}
			for _, message := range fresh.Messages {
				if message.ID == "" || message.AuthorID == "" {
					return ticket.Context{}, errors.New("ticket context message identity missing")
				}
			}
			return fresh, nil
		}
		if attempt+1 < ticketContextAttempts {
			select {
			case <-ctx.Done():
				return ticket.Context{}, ctx.Err()
			case <-time.After(ticketContextRetryDelay):
			}
		}
	}
	return ticket.Context{}, fmt.Errorf("ticket context failed after %d attempts: %w", ticketContextAttempts, err)
}

func (p *Pool) deferForOwnerMessage(job *ticketJob, revision uint64, startedAt time.Time, messages []ticket.Message) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if job.revision != revision {
		return true
	}
	for _, message := range messages {
		if message.AuthorID != job.investigation.DiscordUserID {
			continue
		}
		if id, err := strconv.ParseUint(message.ID, 10, 64); err == nil && id > job.latestMessage {
			job.latestMessage = id
		}
		createdAt, err := time.Parse(time.RFC3339, message.CreatedAt)
		if err != nil || createdAt.After(startedAt) {
			continue
		}
		due := createdAt.Add(p.options.TicketQuietPeriod)
		if due.After(job.due) {
			job.due = due
		}
	}
	if !time.Now().Before(job.due) {
		return false
	}
	job.running = false
	job.revision++
	p.signal()
	return true
}
