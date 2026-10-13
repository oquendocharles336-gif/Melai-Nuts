{{-- Pager for an Alpine list that uses withPager() (resources/js/pager.js). `list` is the component's
     full filtered list (e.g. "filtered"); the bar shows whenever the list has rows. --}}
@props(['list'])
<nav class="pager" aria-label="Pages" x-show="{{ $list }}.length > 0" x-cloak>
    <span class="pager-info" x-text="pageInfo"></span>
    <div class="pager-pages">
        <button type="button" class="pager-btn" aria-label="Previous page" :disabled="curPage <= 1" x-on:click="goPage(curPage - 1)">‹</button>
        <template x-for="(n, i) in pageList" :key="i + '-' + n">
            <button type="button" :class="n === null ? 'pager-gap' : (n === curPage ? 'pager-btn is-on' : 'pager-btn')" :disabled="n === null"
                    :aria-current="n === curPage ? 'page' : null" :aria-label="n === null ? null : 'Page ' + n" x-on:click="n && n !== curPage && goPage(n)"
                    x-text="n === null ? '…' : n"></button>
        </template>
        <button type="button" class="pager-btn" aria-label="Next page" :disabled="curPage >= pageCount" x-on:click="goPage(curPage + 1)">›</button>
    </div>
    <label class="pager-size">Rows
        <select class="select" aria-label="Rows per page" x-on:change="setPerPage($event.target.value)">
            @foreach (\App\Support\ListTools::PAGE_SIZES as $n)<option value="{{ $n }}" :selected="perPage === {{ $n }}">{{ $n }}</option>@endforeach
        </select>
    </label>
</nav>
