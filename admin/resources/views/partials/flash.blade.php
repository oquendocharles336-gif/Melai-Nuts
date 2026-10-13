{{-- Inline messages after a form action (the panel layout also shows them as a toast).
     The <!--flash--> markers keep these one-time messages out of the page's live-refresh hash. --}}
<!--flash-->
@if (session('status')) <div class="flash ok" role="status"><x-icon name="check" :size="16" />{{ session('status') }}</div> @endif
@if (session('error')) <div class="flash bad" role="alert"><x-icon name="alert" :size="16" />{{ session('error') }}</div> @endif
@if ($errors->any())
    <div class="flash bad" role="alert"><x-icon name="alert" :size="16" />
        <ul>@foreach ($errors->all() as $e) <li>{{ $e }}</li> @endforeach</ul>
    </div>
@endif
<!--/flash-->
