import { Injectable } from '@nestjs/common';
import { env } from 'src/env.js';
import { z } from 'zod';

const versionsSchema = z.object({
  versions: z.array(
    z.object({
      component: z.string(),
      version: z.string(),
      source: z.string(),
      lastSeen: z.string().optional(),
    }),
  ),
  unavailableSources: z.array(z.string()),
});

export type VersionResult = z.infer<typeof versionsSchema>;

export type InvestigationRequest = {
  ticketThreadId: string;
  staffThreadId: string;
  discordUserId: string;
  username: string;
  userId: string;
  description: string;
  prompt?: string;
  conversation?: string;
  requestedBy?: string;
};

@Injectable()
export class ColumboRepository {
  get enabled(): boolean {
    return !!env.COLUMBO_URL;
  }

  async getVersions(userId: string): Promise<VersionResult | null> {
    if (!this.enabled) {
      return null;
    }
    const response = await fetch(new URL(`/internal/users/${encodeURIComponent(userId)}/versions`, env.COLUMBO_URL), {
      headers: { 'X-Internal-Secret': env.INTERNAL_SECRET },
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) {
      throw new Error(`columbo version lookup failed: ${response.status} ${response.statusText}`);
    }
    return versionsSchema.parse(await response.json());
  }

  async requestInvestigation(request: InvestigationRequest): Promise<void> {
    if (!this.enabled) {
      return;
    }
    const response = await fetch(new URL('/internal/investigations', env.COLUMBO_URL), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Internal-Secret': env.INTERNAL_SECRET,
      },
      body: JSON.stringify(request),
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) {
      throw new Error(`columbo investigation request failed: ${response.status} ${response.statusText}`);
    }
  }
}
