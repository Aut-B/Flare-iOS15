package dev.dimension.flare.data.repository

import dev.dimension.flare.data.datasource.microblog.datasource.TimelineTabConfigurationDataSource
import dev.dimension.flare.data.model.MixedTimelineTabItem
import dev.dimension.flare.data.model.TabSettings
import dev.dimension.flare.data.model.TimelineTabItem
import dev.dimension.flare.data.model.tab.GroupSource
import dev.dimension.flare.data.model.tab.SYSTEM_HOME_MIXED_TIMELINE_ID
import dev.dimension.flare.data.model.tab.TimelineMergePolicy
import dev.dimension.flare.data.model.tab.TimelinePresentation
import dev.dimension.flare.data.model.tab.TimelineResolver
import dev.dimension.flare.data.model.tab.TimelineSlot
import dev.dimension.flare.data.model.tab.TimelineSlotContent
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiAccount
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.koin.core.annotation.Single

@Single(createdAtStart = true)
internal class AccountTabSyncCoordinator(
    private val accountRepository: AccountRepository,
    private val settingsRepository: SettingsRepository,
    private val coroutineScope: CoroutineScope,
    private val timelineResolver: TimelineResolver,
) {
    init {
        coroutineScope.launch {
            removeTabsForDeletedAccounts()
        }
        coroutineScope.launch {
            ensureTabsForExistingAccounts()
        }
        coroutineScope.launch {
            accountRepository.onAdded.collect { account ->
                addDefaultTabs(account)
            }
        }
        coroutineScope.launch {
            accountRepository.onRemoved.collect { accountKey ->
                removeTabsForAccount(accountKey)
            }
        }
    }

    /**
     * 给「已经添加、但标签栏里什么都没有」的账号补一个默认标签页。
     *
     * `addDefaultTabs` 只在账号新增的那一刻触发。小红书 / Instagram 是先加了账号、
     * 后来才补上 `defaultTabs` 的，所以老账号永远等不到那一次 —— 表现就是
     * 账号在，但标签栏里没有这个平台，等于没法刷。这里在启动时补一次，幂等。
     */
    private suspend fun ensureTabsForExistingAccounts() {
        val accounts = accountRepository.allAccounts.first()
        if (accounts.isEmpty()) return
        val existingSlots = settingsRepository.currentHomeSlots()
        val missing =
            accounts.filter { account ->
                existingSlots.none { slot -> slot.containsAccount(account.accountKey) }
            }
        if (missing.isEmpty()) return
        val extraSlots =
            missing
                .flatMap { account ->
                    (accountRepository.getOrCreateDataSource(account) as? TimelineTabConfigurationDataSource)
                        ?.defaultTabs
                        .orEmpty()
                }.map(timelineResolver::toSlot)
        if (extraSlots.isEmpty()) return
        settingsRepository.updateTabSettingsV2 {
            val newSlots =
                (homeSlots + extraSlots)
                    .distinctBy { it.id }
                    .normalizeSystemHomeMixedTimeline(
                        enabled = homeSlots.anySystemHomeMixedTimeline(),
                    )
            if (newSlots == homeSlots) this else copy(homeSlots = newSlots)
        }
    }

    private fun TimelineSlot.containsAccount(accountKey: MicroBlogKey): Boolean =
        when (val slotContent = content) {
            is TimelineSlotContent.Source -> timelineResolver.resolveAccountKey(this) == accountKey
            is TimelineSlotContent.Group -> slotContent.children.any { it.containsAccount(accountKey) }
        }

    private suspend fun removeTabsForDeletedAccounts() {
        val existingAccounts =
            accountRepository.allAccounts
                .first()
                .mapTo(linkedSetOf()) { it.accountKey }
        settingsRepository.updateTabSettingsV2 {
            copy(
                homeSlots =
                    homeSlots
                        .mapNotNull { it.cleanupForExistingAccounts(existingAccounts) }
                        .normalizeSystemHomeMixedTimeline(
                            enabled = homeSlots.anySystemHomeMixedTimeline(),
                        ),
            )
        }
    }

    private suspend fun addDefaultTabs(account: UiAccount) {
        val defaultTabs =
            (accountRepository.getOrCreateDataSource(account) as? TimelineTabConfigurationDataSource)
                ?.defaultTabs
                .orEmpty()
        if (defaultTabs.isEmpty()) {
            return
        }
        settingsRepository.updateTabSettingsV2 {
            val defaultSlots = defaultTabs.map(timelineResolver::toSlot)
            val shouldEnableSystemHomeMixedTimeline =
                homeSlots.anySystemHomeMixedTimeline() ||
                    homeSlots.countNonSystemHomeTabs() < 2
            val newSlots =
                (homeSlots + defaultSlots)
                    .normalizeSystemHomeMixedTimeline(
                        enabled = shouldEnableSystemHomeMixedTimeline,
                    )
            val newSettings = copy(homeSlots = newSlots)
            if (newSettings == this) {
                this
            } else {
                newSettings
            }
        }
    }

    private suspend fun removeTabsForAccount(accountKey: MicroBlogKey) {
        settingsRepository.updateTabSettingsV2 {
            copy(
                homeSlots =
                    homeSlots
                        .mapNotNull { it.cleanupForRemovedAccount(accountKey) }
                        .normalizeSystemHomeMixedTimeline(
                            enabled = homeSlots.anySystemHomeMixedTimeline(),
                        ),
            )
        }
    }

    private fun TimelineSlot.cleanupForExistingAccounts(accountKeys: Set<MicroBlogKey>): TimelineSlot? =
        cleanupAccountSlots { accountKey ->
            accountKey == null || accountKey in accountKeys
        }

    private fun TimelineSlot.cleanupForRemovedAccount(accountKey: MicroBlogKey): TimelineSlot? =
        cleanupAccountSlots { slotAccountKey ->
            slotAccountKey == null || slotAccountKey != accountKey
        }

    private fun TimelineSlot.cleanupAccountSlots(shouldKeep: (MicroBlogKey?) -> Boolean): TimelineSlot? =
        when (val slotContent = content) {
            is TimelineSlotContent.Source -> {
                if (shouldKeep(timelineResolver.resolveAccountKey(this))) {
                    this
                } else {
                    null
                }
            }

            is TimelineSlotContent.Group -> {
                val sanitizedChildren =
                    slotContent.children
                        .mapNotNull { it.cleanupAccountSlots(shouldKeep) }
                        .distinctBy { it.id }
                if (sanitizedChildren.isEmpty()) {
                    null
                } else if (sanitizedChildren == slotContent.children) {
                    this
                } else {
                    copy(content = slotContent.copy(children = sanitizedChildren))
                }
            }
        }
}

internal fun List<TimelineSlot>.normalizeSystemHomeMixedTimeline(enabled: Boolean): List<TimelineSlot> {
    val deduplicatedSlots = distinctBy { it.id }
    val existingSystemHomeGroup = deduplicatedSlots.firstOrNull { it.isSystemHomeMixedTimeline() }
    val slotsWithoutSystemHomeGroup = deduplicatedSlots.filterNot { it.isSystemHomeMixedTimeline() }
    if (!enabled || slotsWithoutSystemHomeGroup.size < 2) {
        return slotsWithoutSystemHomeGroup
    }

    val systemHomeGroup =
        TimelineSlot(
            id = SYSTEM_HOME_MIXED_TIMELINE_ID,
            content =
                TimelineSlotContent.Group(
                    children = slotsWithoutSystemHomeGroup,
                    source = GroupSource.SystemHome,
                    mergePolicy =
                        (existingSystemHomeGroup?.content as? TimelineSlotContent.Group)?.mergePolicy
                            ?: TimelineMergePolicy.TimePerPage,
                ),
            presentation = existingSystemHomeGroup?.presentation ?: TimelinePresentation(),
        )
    val targetIndex = deduplicatedSlots.indexOfFirst { it.isSystemHomeMixedTimeline() }.takeIf { it >= 0 } ?: 0
    return slotsWithoutSystemHomeGroup
        .toMutableList()
        .apply {
            add(minOf(targetIndex, size), systemHomeGroup)
        }
}

private fun List<TimelineSlot>.anySystemHomeMixedTimeline(): Boolean = any { it.isSystemHomeMixedTimeline() }

private fun List<TimelineSlot>.countNonSystemHomeTabs(): Int = count { !it.isSystemHomeMixedTimeline() }

private fun TimelineSlot.isSystemHomeMixedTimeline(): Boolean = (content as? TimelineSlotContent.Group)?.source == GroupSource.SystemHome

internal fun TabSettings.sanitizeDuplicateTabKeys(): TabSettings {
    val sanitizedTabs =
        mainTabs
            .mapNotNull { it.sanitizeDuplicateTabKeys() }
            .distinctBy { it.key }
    return if (sanitizedTabs == mainTabs) {
        this
    } else {
        copy(mainTabs = sanitizedTabs)
    }
}

private fun TimelineTabItem.sanitizeDuplicateTabKeys(): TimelineTabItem? =
    when (this) {
        is MixedTimelineTabItem -> {
            val sanitizedSubTabs =
                subTimelineTabItem
                    .mapNotNull { it.sanitizeDuplicateTabKeys() }
                    .distinctBy { it.key }
                    .toImmutableList()
            if (sanitizedSubTabs.isEmpty()) {
                null
            } else if (sanitizedSubTabs == subTimelineTabItem) {
                this
            } else {
                copy(subTimelineTabItem = sanitizedSubTabs)
            }
        }

        else -> {
            this
        }
    }
