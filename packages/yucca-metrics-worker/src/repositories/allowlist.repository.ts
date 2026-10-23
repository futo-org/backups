import { Injectable } from '@nestjs/common';
import { Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';

export const InviteSources = ['discord', 'email', 'other'] as const;
export const InviteStates = ['staged', 'invited', 'used'] as const;

export type InviteSource = (typeof InviteSources)[number];
export type InviteState = (typeof InviteStates)[number];

export type InviteCount = {
  source: InviteSource;
  state: InviteState;
  count: number;
};

@Injectable()
export class AllowlistRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  async countInvites(): Promise<InviteCount[]> {
    const rows = await this.db
      .selectFrom('userAllowlist')
      .select((eb) => [
        eb
          .case()
          .when('discordUserId', 'is not', null)
          .then('discord' as InviteSource)
          .when('inviteEmailSentAt', 'is not', null)
          .then('email' as InviteSource)
          .else('other' as InviteSource)
          .end()
          .as('source'),
        eb
          .case()
          .when('inviteUsed', '=', true)
          .then('used' as InviteState)
          .when('invited', '=', true)
          .then('invited' as InviteState)
          .else('staged' as InviteState)
          .end()
          .as('state'),
        eb.fn.countAll<string>().as('count'),
      ])
      .groupBy(['source', 'state'])
      .execute();

    return rows.map(({ source, state, count }) => ({ source, state, count: Number(count) }));
  }
}
