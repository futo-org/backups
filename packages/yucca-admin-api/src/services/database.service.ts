import { Injectable, OnApplicationBootstrap } from '@nestjs/common';
import { DatabaseLock } from 'src/enum.js';
import { DatabaseRepository } from 'src/repositories/database.repository.js';

@Injectable()
export class DatabaseService implements OnApplicationBootstrap {
  constructor(private readonly repository: DatabaseRepository) {}

  async onApplicationBootstrap() {
    await this.repository.withLock(DatabaseLock.Migrations, () => this.repository.runMigrations());
  }
}
