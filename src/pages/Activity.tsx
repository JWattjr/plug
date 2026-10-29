import { ActivityFeed } from '@/components/ActivityFeed'
import { Page, PageTitle } from '@/components/ui'

export default function Activity() {
  return (
    <Page narrow>
      <PageTitle title="Activity" subtitle="Everything the contract has done, newest first: campaigns, instant sales, and every step of every protected order." />
      <ActivityFeed />
    </Page>
  )
}
