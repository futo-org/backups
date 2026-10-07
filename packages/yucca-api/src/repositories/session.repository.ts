import { Injectable } from '@nestjs/common';
import { Insertable, Kysely } from 'kysely';
import { InjectKysely } from 'nestjs-kysely';
import { DB } from 'src/schema/index.js';
import { SessionTable } from 'src/schema/tables/session.table.js';

@Injectable()
export class SessionRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  create(session: Insertable<SessionTable>) {
    return this.db.insertInto('sessions').values(session).returningAll().executeTakeFirstOrThrow();
  }

  delete(id: string) {
    return this.db.deleteFrom('sessions').where('id', '=', id).execute();
  }
}
